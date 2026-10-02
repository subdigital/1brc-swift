import Foundation

struct Measurement {
    let cityKey: CityKey
    let temperature: Temperature
}

struct Temperature: ExpressibleByIntegerLiteral, Comparable {
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

struct CityKey: Hashable {
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

struct Entry {
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

    var avg: Double {
        sum.doubleValue / Double(count)
    }
}

extension Entry {
    func formatted(name: String, using nf: NumberFormatter) -> String {
        let min = nf.string(from: self.min.doubleValue as NSNumber)!
        let max = nf.string(from: self.max.doubleValue as NSNumber)!
        let avg = nf.string(from: self.avg as NSNumber)!
        return "\(name)=\(min)/\(max)/\(avg)"
    }
}

extension UInt8 {
    static let semi: UInt8 = 0x3b
    static let newline: UInt8 = 0x0a
    static let minusSign: UInt8 = 0x2d
    static let period: UInt8 = 0x2e
    static let zero: UInt8 = 0x30
}

func fastFind(from pointer: UnsafeRawPointer, target: UInt8, maxSearch: Int) -> (UnsafeRawPointer, Int)? {
    guard let targetPointerMut = memchr(pointer, Int32(target), maxSearch) else {
        return nil
    }

    let targetPtr = UnsafeRawPointer(targetPointerMut)
    return (targetPtr, pointer.distance(to: targetPtr))
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

func run(inputFile: String) throws {
    let fileURL = URL(fileURLWithPath: inputFile)
    let data = try Data(contentsOf: fileURL)
    let fmt = ByteCountFormatter()
    var stderr = StandardErrorStream()
    print("Loaded \(fmt.string(fromByteCount: Int64(data.count)))", to: &stderr)

    var results = [CityKey: Entry]()
    var offset = 0
    var count = 0

    data.withUnsafeBytes { bufferPointer in
        while let reading = parseReading(from: bufferPointer, offset: &offset) {
            count += 1
            results[reading.cityKey, default: Entry()].update(from: reading)
        }

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
}

struct StandardErrorStream: TextOutputStream {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

@main
struct brc {
    static func main() throws {
        let inputFile = ProcessInfo.processInfo.environment["INPUT_FILE"] ?? "measurements.txt"
        try run(inputFile: inputFile)
    }
}
