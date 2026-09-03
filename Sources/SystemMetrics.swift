import Foundation
import IOKit
import Darwin

struct DiskInfo: Identifiable, Hashable {
    let name: String
    let path: String
    let total: UInt64
    let free: UInt64
    let isInternal: Bool

    var id: String { path }
    var used: UInt64 { total > free ? total - free : 0 }
    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct MemoryStats {
    var used: UInt64 = 0
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// Archivos en caché: macOS los mantiene por rendimiento y los suelta apenas
    /// alguien necesite la memoria, así que no cuentan como uso.
    var cached: UInt64 = 0
    var pressure: Double = 0

    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    var cachedFraction: Double { total == 0 ? 0 : Double(cached) / Double(total) }
}

/// Muestreo diferencial de los ticks de CPU del kernel.
final class CPUSampler {
    private var previousBusy: UInt64 = 0
    private var previousTotal: UInt64 = 0

    func sample() -> Double {
        var cpuCount = natural_t(0)
        var infoCount = mach_msg_type_number_t(0)
        var info: processor_info_array_t?

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }

        let deltaBusy = busy &- previousBusy
        let deltaTotal = total &- previousTotal
        let hadBaseline = previousTotal > 0
        previousBusy = busy
        previousTotal = total

        guard hadBaseline, deltaTotal > 0 else { return 0 }
        return min(1, max(0, Double(deltaBusy) / Double(deltaTotal)))
    }
}

enum SystemMetrics {

    // MARK: - Memoria

    static func memory() -> MemoryStats {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryStats(used: 0, total: total) }

        let page = UInt64(vm_kernel_page_size)
        let appMemory = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)

        let used = min((appMemory + wired + compressed) * page, total)
        let pressure = total == 0 ? 0 : Double((wired + compressed) * page) / Double(total)

        return MemoryStats(used: used,
                           total: total,
                           app: appMemory * page,
                           wired: wired * page,
                           compressed: compressed * page,
                           cached: UInt64(stats.external_page_count) * page,
                           pressure: min(1, pressure))
    }

    // MARK: - GPU

    /// El servicio del acelerador se busca una sola vez y se reutiliza: hacerlo en
    /// cada muestra construía un diccionario completo del IORegistry por segundo.
    private static var accelerator: io_object_t = 0

    /// Utilización del acelerador leída del IORegistry. No requiere privilegios.
    static func gpuUtilization() -> Double? {
        if accelerator == 0 {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                               IOServiceMatching("IOAccelerator"),
                                               &iterator) == KERN_SUCCESS else { return nil }
            defer { IOObjectRelease(iterator) }
            accelerator = IOIteratorNext(iterator)
            guard accelerator != 0 else { return nil }
        }

        guard let property = IORegistryEntryCreateCFProperty(accelerator,
                                                             "PerformanceStatistics" as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let performance = property as? [String: Any]
        else {
            IOObjectRelease(accelerator)
            accelerator = 0
            return nil
        }

        for key in ["Device Utilization %", "Renderer Utilization %", "GPU Activity(%)"] {
            if let number = performance[key] as? NSNumber {
                return min(1, max(0, number.doubleValue / 100))
            }
        }
        return nil
    }

    // MARK: - Discos

    static func volumes() -> [DiskInfo] {
        var result: [DiskInfo] = []
        var seen = Set<String>()

        if let boot = describe(URL(fileURLWithPath: "/")) {
            result.append(boot)
            seen.insert(boot.name)
        }

        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsInternalKey]
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                           options: [.skipHiddenVolumes]) ?? []
        for url in mounted where url.path != "/" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  let disk = describe(url),
                  !seen.contains(disk.name)
            else { continue }
            result.append(disk)
            seen.insert(disk.name)
        }
        return result
    }

    private static func describe(_ url: URL) -> DiskInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }

        let free = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? 0
        let name = values.volumeName ?? url.lastPathComponent
        return DiskInfo(name: name.isEmpty ? L10n.storageUnnamed : name,
                        path: url.path,
                        total: UInt64(total),
                        free: free,
                        isInternal: values.volumeIsInternal ?? true)
    }
}
