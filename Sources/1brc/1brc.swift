import Foundation

typealias Results = [CityKey: Entry]

struct Slot {
    var keyptr: UnsafeRawBufferPointer?
    var hash: UInt64 = 0
    var entry = Entry()
}

struct StationTable: ~Copyable {
    static let capacity = 1 << 14  // 16,384
    static let mask = capacity - 1
    private var slots: UnsafeMutablePointer<Slot>
    private(set) var count = 0

    init() {
        slots = .allocate(capacity: Self.capacity)
        slots.initialize(repeating: Slot(), count: Self.capacity)
    }

    deinit {
        slots.deallocate()
    }

    mutating func add(
        cityPointer: UnsafeRawBufferPointer,
        hash: UInt64,
        temperature: Temperature
    ) {
        var index = Int(truncatingIfNeeded: hash) & Self.mask

        while true {
            let slot = self.slots + index
            if slot.pointee.keyptr == nil {
                // empty slot
                var entry = Entry()
                entry.update(from: temperature)
                slot.pointee = Slot(
                    keyptr: cityPointer,
                    hash: hash,
                    entry: entry
                )
                return
            } else {
                // is it the same city?
                if slot.pointee.hash == hash &&
                   slot.pointee.keyptr!.count == cityPointer.count &&
                    memcmp(slot.pointee.keyptr!.baseAddress, cityPointer.baseAddress, cityPointer.count) == 0
                {
                    // same, merge
                    slot.pointee.entry.update(from: temperature)
                    return
                }

                // collision, linear probe next slot
                index = (index + 1) & Self.mask
            }
        }
    }

    func makeResults() -> Results {
        var results = Results()
        for i in 0..<Self.capacity {
            let slot = (self.slots + i).pointee
            guard let keyptr = slot.keyptr else { continue }

            let key = CityKey(buffer: keyptr)
            results[key] = slot.entry
        }
        return results
    }
}


struct Temperature: ExpressibleByIntegerLiteral, Comparable, Sendable {
    let tenths: Int

    init(integerLiteral value: IntegerLiteralType) {
        tenths = value
    }

    init(tenths: Int) {
        self.tenths = tenths
    }

    var doubleValue: Double {
        Double(tenths) / 10
    }

    static func + (lhs: Temperature, rhs: Temperature) -> Temperature {
        Temperature(tenths: lhs.tenths + rhs.tenths)
    }

    static func += (lhs: inout Temperature, rhs: Temperature) {
        lhs = Temperature(tenths: lhs.tenths + rhs.tenths)
    }

    static func < (lhs: Temperature, rhs: Temperature) -> Bool {
        lhs.tenths < rhs.tenths
    }
}

struct CityKey: Hashable, @unchecked Sendable {
    let buffer: UnsafeRawBufferPointer

    func hash(into hasher: inout Hasher) {
        hasher.combine(bytes: buffer)
    }

    func decodeName() -> String {
        let nameData = Data(buffer: buffer.assumingMemoryBound(to: UInt8.self))
        return String(data: nameData, encoding: .utf8)!
    }

    static func == (lhs: CityKey, rhs: CityKey) -> Bool {
        return lhs.buffer.count == rhs.buffer.count && memcmp(lhs.buffer.baseAddress, rhs.buffer.baseAddress, lhs.buffer.count) == 0
    }
}

struct Entry: Sendable {
    var min: Temperature = 0
    var max: Temperature = 0
    var sum: Temperature = 0
    var count: Int = 0

    mutating func update(from temperature: Temperature) {
        if count == 0 {
            min = temperature
            max = temperature
        } else {
            min = Swift.min(min, temperature)
            max = Swift.max(max, temperature)
        }

        sum += temperature
        count += 1
    }

    mutating func merge(_ other: Entry) {
        guard other.count > 0 else { return }

        if count == 0 {
            self = other
            return
        }

        min = Swift.min(min, other.min)
        max = Swift.max(max, other.max)
        sum += other.sum
        count += other.count
    }

    var avg: Double {
        sum.doubleValue / Double(count)
    }
}

extension Entry {
    func formatted(name: String, using formatter: NumberFormatter) -> String {
        let minimum = format(min.doubleValue, using: formatter)
        let maximum = format(max.doubleValue, using: formatter)
        let average = format(avg, using: formatter)
        return "\(name)=\(minimum)/\(maximum)/\(average)"
    }

    private func format(_ value: Double, using formatter: NumberFormatter) -> String {
        let formattedValue = formatter.string(from: value as NSNumber)!
        return formattedValue == "-0.0" ? "0.0" : formattedValue
    }
}

extension UInt8 {
    static let semi: UInt8 = 0x3b
    static let newline: UInt8 = 0x0a
    static let minusSign: UInt8 = 0x2d
    static let period: UInt8 = 0x2e
    static let zero: UInt8 = 0x30
}

@inline(__always)
func fastFind(from pointer: UnsafeRawPointer, target: UInt8, maxSearch: Int) -> (UnsafeRawPointer, Int)? {
    guard let targetPointerMut = memchr(pointer, Int32(target), maxSearch) else {
        return nil
    }

    let targetPtr = UnsafeRawPointer(targetPointerMut)
    return (targetPtr, pointer.distance(to: targetPtr))
}

func chunkRanges(in file: borrowing MappedFile, count: Int) -> [Range<Int>] {
    guard file.size > 0, count > 0 else { return [] }

    let targetSize = file.size / count
    var ranges: [Range<Int>] = []
    var start = 0

    for index in 1..<count {
        let target = index * targetSize
        guard target > start else { continue }

        guard let (_, distance) = fastFind(
            from: file.ptr + target,
            target: .newline,
            maxSearch: file.size - target
        ) else {
            break
        }

        let end = target + distance + 1
        ranges.append(start..<end)
        start = end
    }

    if start < file.size {
        ranges.append(start..<file.size)
    }

    return ranges
}

func parseReading(from buffer: UnsafeRawBufferPointer, offset: inout Int, using table: inout StationTable) -> Bool {
    let ptr = buffer.baseAddress! + offset
    var maxSearch = buffer.count - offset

    guard let (semiPtr, stationSize) = fastFind(
        from: ptr,
        target: .semi,
        maxSearch: maxSearch
    ) else {
        return false
    }

    maxSearch -= stationSize + 1
    guard let (_, temperatureSize) = fastFind(
        from: semiPtr + 1,
        target: .newline,
        maxSearch: maxSearch
    ) else {
        return false
    }

    let nameBuffer = UnsafeRawBufferPointer(start: ptr, count: stationSize)

    let tempBuffer = UnsafeRawBufferPointer(start: semiPtr + 1, count: temperatureSize)
    let temp = parseTemperature(buffer: tempBuffer)

    offset += stationSize + 1 + tempBuffer.count + 1 // account for delimiters

    let hash = fnvHash(nameBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: nameBuffer.count)
    table.add(cityPointer: nameBuffer, hash: hash, temperature: temp)

    return true
}

func parseTemperature(buffer: UnsafeRawBufferPointer) -> Temperature {
    let buffer = buffer.assumingMemoryBound(to: UInt8.self)
    let ptr = buffer.baseAddress!
    var sum = 0
    var pos = 0
    let isNegative = ptr[0] == UInt8.minusSign
    if isNegative {
        pos += 1
    }

    while pos < buffer.count {
        sum *= 10
        if ptr[pos] == .period {
            pos += 1
        }

        let value = ptr[pos] - .zero
        sum += Int(value)
        pos += 1
    }

    let tenths = (isNegative ? -1 : 1) * sum
    return Temperature(tenths: tenths)
}

struct MappedFile: ~Copyable {
    let ptr: UnsafeMutableRawPointer
    let size: Int
    let fd: Int32

    init(path: String) {
        fd = open(path, O_RDONLY)
        precondition(fd >= 0, "open failed: \(errno)")

        var status = stat()
        precondition(fstat(fd, &status) == 0, "fstat failed: \(errno)")
        size = Int(status.st_size)

        ptr = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)!
    }

    deinit {
        munmap(ptr, size)
        close(fd)
    }

    var bufferPointer: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: ptr, count: size)
    }
}

func processResults(in file: borrowing MappedFile, ranges: [Range<Int>]) async -> Results {
    nonisolated(unsafe) let buffer = file.bufferPointer
    return await withTaskGroup(of: Results.self, returning: Results.self) { group in
        for range in ranges {
            group.addTask {
                processRange(in: buffer, range: range)
            }
        }

        var results: Results = [:]
        for await partialResults in group {
            for (cityKey, entry) in partialResults {
                results[cityKey, default: Entry()].merge(entry)
            }
        }
        return results
    }
}

private func processRange(in buffer: UnsafeRawBufferPointer, range: Range<Int>) -> Results {
    let subBuffer = UnsafeRawBufferPointer(
        start: buffer.baseAddress! + range.lowerBound,
        count: range.count
    )
    var offset = 0
    var table = StationTable()
    while offset < subBuffer.count {
        if !parseReading(from: subBuffer, offset: &offset, using: &table) {
            break
        }
    }

    return table.makeResults()
}

func run(inputFile: String) async throws {
    let fileURL = URL(fileURLWithPath: inputFile)

    let file = MappedFile(path: fileURL.path())
    let fmt = ByteCountFormatter()
    var stderr = StandardErrorStream()
    print("Loaded \(fmt.string(fromByteCount: Int64(file.size)))", to: &stderr)

    let ranges = chunkRanges(
        in: file,
        count: ProcessInfo.processInfo.activeProcessorCount
    )
    let results = await processResults(in: file, ranges: ranges)

    let nf = NumberFormatter()
    nf.minimumFractionDigits = 1
    nf.maximumFractionDigits = 1
    let entries = results.keys.reduce(into: [String: Entry]()) { partialResult, cityKey in
        let name = cityKey.decodeName()
        partialResult[name] = results[cityKey]!
    }
    for key in entries.keys.sorted() {
        print(entries[key]!.formatted(name: key, using: nf))
    }
}

struct StandardErrorStream: TextOutputStream {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

@main
struct brc {
    static func main() async throws {
        let inputFile = ProcessInfo.processInfo.environment["INPUT_FILE"] ?? "measurements.txt"
        try await run(inputFile: inputFile)
    }
}

// https://en.wikipedia.org/wiki/Fowler–Noll–Vo_hash_function
func fnvHash(_ pointer: UnsafePointer<UInt8>, count: Int) -> UInt64 {
    let FNVPrime: UInt64 = 1099511628211
    let FNVOffsetBasis: UInt64 = 14695981039346656037

    var hash: UInt64 = FNVOffsetBasis

    for i in 0..<count {
        hash = (hash ^ UInt64(pointer[i])) &* FNVPrime
    }

    return hash
}
