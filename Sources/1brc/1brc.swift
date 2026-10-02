import Foundation

struct Measurement {
    let cityKey: CityKey
    let temperature: Double
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
    var min: Double = 0
    var max: Double = 0
    var sum: Double = 0
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
        sum / Double(count)
    }
}

extension Entry {
    func formatted(name: String, using nf: NumberFormatter) -> String {
        let min = nf.string(from: self.min as NSNumber)!
        let max = nf.string(from: self.max as NSNumber)!
        let avg = nf.string(from: self.avg as NSNumber)!
        return "\(name)=\(min)/\(max)/\(avg)"
    }
}

extension UInt8 {
    static let semi: UInt8 = 0x3b
    static let newline: UInt8 = 0x0a
}

func parseReading(from buffer: UnsafeRawBufferPointer, offset: inout Int) -> Measurement? {
    let ptr = buffer.baseAddress! + offset
    let maxSearch = buffer.count - offset
    guard let semiPtr = memchr(ptr, Int32(UInt8.semi), maxSearch) else { return nil }

    let stationSize = ptr.distance(to: semiPtr)
    let bytesAfterSemicolon = maxSearch - stationSize - 1

    guard let newLinePtr = memchr(semiPtr + 1, Int32(UInt8.newline), bytesAfterSemicolon) else { return nil }
    let temperatureCount = (semiPtr + 1).distance(to: newLinePtr)

    let nameBuffer = UnsafeRawBufferPointer(start: ptr, count: stationSize)

    let tempBuffer = UnsafeRawBufferPointer(start: semiPtr + 1, count: temperatureCount)
    let tempData = Data(buffer: tempBuffer.assumingMemoryBound(to: UInt8.self))
    let tempStr = String(data: tempData, encoding: .utf8)!
    let temp = Double(tempStr)!

    offset += stationSize + 1 + temperatureCount + 1 // account for delimiters

    return Measurement(cityKey: CityKey(buffer: nameBuffer), temperature: temp)
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
