import Foundation

typealias Results = [CityKey: Entry]

struct Measurement: Sendable {
    let cityKey: CityKey
    let temperature: Temperature
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

// Safety invariant: the mapped bytes are immutable and every key is consumed before
// its owning MappedFile leaves scope.
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
    var cityKey: CityKey?
    var min: Temperature = 0
    var max: Temperature = 0
    var sum: Temperature = 0
    var count: Int = 0

    mutating func update(from measurement: Measurement) {
        cityKey = measurement.cityKey

        if count == 0 {
            min = measurement.temperature
            max = measurement.temperature
        } else {
            min = Swift.min(min, measurement.temperature)
            max = Swift.max(max, measurement.temperature)
        }

        sum += measurement.temperature
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

func parseReading(from buffer: UnsafeRawBufferPointer, offset: inout Int) -> Measurement? {
    let ptr = buffer.baseAddress! + offset
    var maxSearch = buffer.count - offset

    guard let (semiPtr, stationSize) = fastFind(
        from: ptr,
        target: .semi,
        maxSearch: maxSearch
    ) else {
        return nil
    }

    maxSearch -= stationSize + 1
    guard let (_, temperatureSize) = fastFind(
        from: semiPtr + 1,
        target: .newline,
        maxSearch: maxSearch
    ) else {
        return nil
    }

    let nameBuffer = UnsafeRawBufferPointer(start: ptr, count: stationSize)

    let tempBuffer = UnsafeRawBufferPointer(start: semiPtr + 1, count: temperatureSize)
    let temp = parseTemperature(buffer: tempBuffer)

    offset += stationSize + 1 + tempBuffer.count + 1 // account for delimiters

    return Measurement(cityKey: CityKey(buffer: nameBuffer), temperature: temp)
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
    let buffer = UnsafeRawBufferPointer(
        start: buffer.baseAddress! + range.lowerBound,
        count: range.count
    )
    var results: Results = [:]
    var offset = 0

    while let reading = parseReading(from: buffer, offset: &offset) {
        results[reading.cityKey, default: Entry()].update(from: reading)
    }

    return results
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
