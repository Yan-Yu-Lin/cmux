import Foundation

/// A validated expanded Dynamic Notch viewport size.
public struct DynamicNotchDisplaySize: Equatable, Sendable {
    public static let widthRange = 300.0 ... 1_200.0
    public static let heightRange = 160.0 ... 1_400.0

    public let width: Double
    public let height: Double

    public init?(width: Double, height: Double) {
        guard width.isFinite,
            height.isFinite,
            Self.widthRange.contains(width),
            Self.heightRange.contains(height)
        else {
            return nil
        }
        self.width = width
        self.height = height
    }

    public static func clamped(
        width: Double,
        height: Double
    ) -> DynamicNotchDisplaySize {
        DynamicNotchDisplaySize(
            width: min(max(width, widthRange.lowerBound), widthRange.upperBound),
            height: min(
                max(height, heightRange.lowerBound),
                heightRange.upperBound
            )
        )!
    }
}

/// Validated per-display expanded viewport sizes.
///
/// Values remain string-backed because the settings-file reconciler supports
/// flat string dictionaries. JSON callers read and write nested width/height
/// objects.
public enum DynamicNotchDisplaySizeSettings {
    public static func size(
        for displayKey: String,
        in serializedSizes: [String: String]
    ) -> DynamicNotchDisplaySize? {
        guard let rawValue = serializedSizes[displayKey] else { return nil }
        let components = rawValue.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
            let width = Double(components[0]),
            let height = Double(components[1])
        else {
            return nil
        }
        return DynamicNotchDisplaySize(width: width, height: height)
    }

    public static func setting(
        _ size: DynamicNotchDisplaySize,
        for displayKey: String,
        in serializedSizes: [String: String]
    ) -> [String: String] {
        guard !displayKey.isEmpty else { return serializedSizes }
        var result = serializedSizes
        result[displayKey] = "\(size.width),\(size.height)"
        return result
    }

    public static func removing(
        displayKey: String,
        from serializedSizes: [String: String]
    ) -> [String: String] {
        var result = serializedSizes
        result.removeValue(forKey: displayKey)
        return result
    }

    public static func serializedSizes(
        fromJSONObject raw: Any?
    ) -> [String: String]? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        result.reserveCapacity(dictionary.count)
        for (displayKey, rawSize) in dictionary {
            guard !displayKey.isEmpty,
                let object = rawSize as? [String: Any],
                Set(object.keys) == Set(["width", "height"]),
                let rawWidth = object["width"] as? NSNumber,
                let rawHeight = object["height"] as? NSNumber,
                CFGetTypeID(rawWidth) != CFBooleanGetTypeID(),
                CFGetTypeID(rawHeight) != CFBooleanGetTypeID(),
                let size = DynamicNotchDisplaySize(
                    width: rawWidth.doubleValue,
                    height: rawHeight.doubleValue
                )
            else {
                return nil
            }
            result[displayKey] = "\(size.width),\(size.height)"
        }
        return result
    }

    public static func jsonObject(
        from serializedSizes: [String: String]
    ) -> [String: [String: Double]] {
        serializedSizes.reduce(into: [:]) { result, entry in
            guard let size = size(
                for: entry.key,
                in: serializedSizes
            ) else {
                return
            }
            result[entry.key] = [
                "width": size.width,
                "height": size.height,
            ]
        }
    }
}
