import Foundation

struct Measurement {
    let name: String
    let temperature: Double
}

struct Entry {
    var name: String = ""
    var min: Double = 0
    var max: Double = 0
    var sum: Double = 0
    var count: Int = 0

    mutating func update(from measurement: Measurement) {
        name = measurement.name

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
    func formatted(using nf: NumberFormatter) -> String {
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

func parseReading(from data: Data, index: inout Int) -> Measurement? {
    let slice = data[index...]
    guard let semiIndex = slice.firstIndex(of: .semi),
        let newLineIndex = slice.firstIndex(of: .newline) else {
            return nil
        }

    let name = String(data: slice[index..<semiIndex], encoding: .utf8)!
    let tempStr = String(data: slice[(semiIndex + 1)..<newLineIndex], encoding: .utf8)!
    let temp = Double(tempStr)!
    index = newLineIndex + 1
    return Measurement(name: name, temperature: temp)
}

func run(inputFile: String) throws {
    let fileURL = URL(fileURLWithPath: inputFile)
    let data = try Data(contentsOf: fileURL)
    let fmt = ByteCountFormatter()
    var stderr = StandardErrorStream()
    print("Loaded \(fmt.string(fromByteCount: Int64(data.count)))", to: &stderr)

    var results = [String: Entry]()
    var index = 0
    var count = 0

    while let reading = parseReading(from: data, index: &index) {
        count += 1
            var entry = results[reading.name] ?? Entry()
            entry.update(from: reading)
            results[reading.name] = entry
    }

    let nf = NumberFormatter()
    nf.minimumFractionDigits = 1
    nf.maximumFractionDigits = 1
    for key in results.keys.sorted() {
        print(results[key]!.formatted(using: nf))
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
