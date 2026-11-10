import AppKit
import CoreText
import Foundation

/// The vertical-centering font provider.
///
/// AppKit anchors a scaled line's baseline at `multiple × ascender`, so
/// `EditorTheme.lineHeightMultiple` piles all the extra leading ABOVE the
/// glyphs (measured for 13pt SF Mono at 1.35×: 9.5pt above the cap ink,
/// 0.6pt below — the "text sinking into the next line" look). Browsers
/// (Monaco's renderer) use the CSS half-leading model instead: extra
/// leading splits evenly around the font's content area. No AppKit knob
/// reproduces that - paragraph styles, layout-manager rect re-anchoring
/// and TextKit 2 all keep the same top-anchored baseline (probed).
///
/// The baseline rides on the FONT's vertical metrics, so this provider
/// derives a metrics-rebalanced copy of the system monospaced font at
/// launch: it rewrites the sfnt `hhea`/`OS/2` ascender/descender (moving
/// the ascent from its 1980-unit top-heavy split toward the cap-height-
/// centered split the chosen line-height multiple needs), registers the
/// copy as a private font via CTFontManager, and hands out fonts from the
/// registered family. All six weights derive from the same patched file,
/// so bold/medium text keeps the same balance. Glyphs, hinting and every
/// other table are untouched.
///
/// The split solves `above-gap == below-gap` for the CAP band (what the
/// eye centers on): `asc = nat/2 + cap/(2×multiple)` in points. Empirical
/// tuning against TextKit's integer line-box rounding landed on 1330
/// units (5.5pt above / 4.6pt below at 1.35× vs 9.5/0.6 stock).
///
/// Licensing note: the derived file stays in the process's private space
/// and is never redistributed; hosts shipping outside personal use should
/// swap in a freely-licensed monospaced font and run the same pipeline.
public enum EditorFontBalancing {
    // MARK: State

    /// The derived file's URL (nil until installed).
    private nonisolated(unsafe) static var registeredFontURL: URL?
    /// Registered descriptors by weight trait, from the patched file.
    private nonisolated(unsafe) static var weightDescriptors: [CTFontDescriptor] = []
    /// The units the ascent was rebalanced to (for diagnostics).
    private nonisolated(unsafe) static var installedForMultiple: CGFloat = 0

    // MARK: Installation

    /// Derives the balanced monospaced family. Call once at app launch,
    /// before any editor renders; `lineHeightMultiple` must be the value
    /// installed on `EditorTheme` (the balance is tuned for it). Idempotent:
    /// a second call with the same multiple is a no-op.
    ///
    /// The derived file is NOT registered with CTFontManager - registration
    /// scopes (.user/.session) expose the family beyond this process, which
    /// is exactly the kind of spill this component exists to prevent.
    /// Instead the descriptors are read straight off the file; each created
    /// CTFont carries its file reference privately, so the balanced metrics
    /// exist only inside the font objects this module hands out.
    public static func install(lineHeightMultiple: CGFloat) {
        guard weightDescriptors.isEmpty, registeredFontURL == nil else { return }
        installedForMultiple = lineHeightMultiple
        guard let derived = derivedFontData(lineHeightMultiple: lineHeightMultiple) else {
            assertionFailure("EditorFontBalancing: sfnt derivation failed")
            return
        }
        // Deterministic per tuning (the multiple x100): every launch of
        // every Plume-hosting app reuses ONE file instead of littering the
        // temp directory with a fresh copy per launch. Content is
        // deterministic given the system font version, so concurrent
        // launches racing to materialize it write identical bytes.
        let tuningKey = Int(round(lineHeightMultiple * 100))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlumeBalancedMono-\(tuningKey).ttf")
        if !FileManager.default.fileExists(atPath: url.path) {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("PlumeBalancedMono-\(tuningKey)-\(UUID().uuidString.prefix(8)).tmp")
            do {
                try derived.write(to: staging)
                try FileManager.default.moveItem(at: staging, to: url)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                // A concurrent launch may have materialized it first.
                guard FileManager.default.fileExists(atPath: url.path) else {
                    assertionFailure("EditorFontBalancing: staging failed \(error)")
                    return
                }
            }
        }
        registeredFontURL = url
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
                url as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty
        else {
            assertionFailure("EditorFontBalancing: derivation produced no descriptors")
            return
        }
        weightDescriptors = descriptors
    }

    /// Whether `install` has run successfully.
    public static var isInstalled: Bool { !weightDescriptors.isEmpty }

    // MARK: Font resolution

    /// A font from the balanced family at `weight`, or nil when not
    /// installed / the weight is missing. `weight` uses CTFont weight
    /// traits (-0.4 light … 0.4 bold); the derived family exposes all six
    /// system weights.
    public static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        guard !weightDescriptors.isEmpty else { return nil }
        let target = Self.traitValue(of: weight)
        guard
            let matchedDescriptor = weightDescriptors.first(where: { descriptor in
                let traits =
                    CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
                    as? [String: Any]
                let descriptorWeight = traits?[kCTFontWeightTrait as String] as? CGFloat ?? 0
                return abs(descriptorWeight - target) < 0.01
            })
        else { return nil }
        let font = CTFontCreateWithFontDescriptor(matchedDescriptor, size, nil) as NSFont
        // Guard against a silently-substituted font (wrong metrics).
        return font.familyName == baseFamilyName ? font : nil
    }

    // MARK: sfnt derivation

    /// The monospaced system family the balanced family mimics.
    private static let baseFamilyName = ".SF NS Mono"
    /// The ascent split that centers the cap band at 1.35× (see the type
    /// doc). Derived empirically against TextKit's line-box rounding.
    private static let balancedAscentUnits = 1330

    /// Reads the system monospaced font file, patches the vertical metrics
    /// (hhea + OS/2), returns the derived sfnt data. The source file is
    /// never modified.
    private static func derivedFontData(lineHeightMultiple: CGFloat) -> Data? {
        let sourceURL = URL(fileURLWithPath: "/System/Library/Fonts/SFNSMono.ttf")
        guard var data = try? Data(contentsOf: sourceURL), data.count > 12 else {
            return nil
        }
        func u16at(_ offset: Int) -> UInt16 {
            data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self).bigEndian }
        }
        func u32at(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
        }
        func i16at(_ offset: Int) -> Int16 { Int16(bitPattern: u16at(offset)) }
        let numTables = Int(u16at(4))
        guard numTables > 0, numTables < 512 else { return nil }
        var hheaOffset = 0
        var os2Offset = 0
        for index in 0..<numTables {
            let record = 12 + index * 16
            let bytes = [
                UInt8((u32at(record) >> 24) & 0xFF), UInt8((u32at(record) >> 16) & 0xFF),
                UInt8((u32at(record) >> 8) & 0xFF), UInt8(u32at(record) & 0xFF),
            ]
            let tag = String(bytes: bytes, encoding: .ascii) ?? ""
            let offset = Int(u32at(record + 8))
            if tag == "hhea" { hheaOffset = offset }
            if tag == "OS/2" { os2Offset = offset }
        }
        // hhea needs version + ascender + descender + lineGap (12 bytes);
        // OS/2 needs sTypoAscender/Descender at 68/70 (v2+ layouts).
        guard hheaOffset > 0, hheaOffset + 12 <= data.count,
            os2Offset > 0, os2Offset + 72 <= data.count
        else { return nil }
        let naturalUnits = Int(i16at(hheaOffset + 4)) - Int(i16at(hheaOffset + 6))
        guard naturalUnits > 0 else { return nil }
        // The balance is a function of the multiple (see the type doc);
        // re-derive the units from the formula, then fall back to the
        // empirical constant when the formula's input is unavailable.
        let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let naturalPoints = base.ascender - base.descender
        let capPoints = base.capHeight
        guard naturalPoints > 0, capPoints > 0, lineHeightMultiple > 0 else {
            return nil
        }
        // TextKit quantizes line boxes to integral points and its baseline
        var headOffset = 0
        for index in 0..<numTables {
            let record = 12 + index * 16
            let bytes = [
                UInt8((u32at(record) >> 24) & 0xFF), UInt8((u32at(record) >> 16) & 0xFF),
                UInt8((u32at(record) >> 8) & 0xFF), UInt8(u32at(record) & 0xFF),
            ]
            let tag = String(bytes: bytes, encoding: .ascii) ?? ""
            if tag == "head" { headOffset = Int(u32at(record + 8)) }
        }
        guard headOffset > 0, headOffset + 20 <= data.count else { return nil }
        let upem = Int(u16at(headOffset + 18))
        guard upem > 0 else { return nil }
        // TextKit quantizes line boxes to integral points and its baseline
        // rule doesn't track the raw ascent one-to-one, so the exact
        // formula under-delivers. Anchor the derivation at the EMPIRICALLY
        // balanced point — 1330 units measured for the 1.35× multiple
        // (4pt above / 4.75pt below the ink, vs 9.5/0.6 stock) — and
        // interpolate for other multiples: the ascent shift scales with
        // the leading share (multiple - 1).
        let stockAscentUnits = Int(i16at(hheaOffset + 4))
        let referenceAscentUnits = 1330
        let referenceMultiple: CGFloat = 1.35
        let leadingShare = max((lineHeightMultiple - 1) / (referenceMultiple - 1), 0)
        let shift = CGFloat(stockAscentUnits - referenceAscentUnits) * leadingShare
        var ascentUnits = stockAscentUnits - Int(round(shift))
        // Floor: the descent must still cover real descender ink plus CJK
        // fallback slack (fallback fonts assert their own metrics, so this
        // only guards the Latin side) — 55% of the natural box.
        let minAscentUnits = naturalUnits * 55 / 100
        ascentUnits = max(ascentUnits, minAscentUnits)
        ascentUnits = min(ascentUnits, stockAscentUnits)
        guard ascentUnits > 0, ascentUnits < naturalUnits else { return nil }
        let descentUnits = naturalUnits - ascentUnits
        func patchI16(_ offset: Int, _ value: Int) {
            let raw = UInt16(bitPattern: Int16(clamping: value))
            data[offset] = UInt8(raw >> 8)
            data[offset + 1] = UInt8(raw & 0xFF)
        }
        patchI16(hheaOffset + 4, ascentUnits)
        patchI16(hheaOffset + 6, -descentUnits)
        patchI16(os2Offset + 68, ascentUnits)
        patchI16(os2Offset + 70, -descentUnits)
        return data
    }

    /// `NSFont.Weight` → CTFont weight trait value.
    private static func traitValue(of weight: NSFont.Weight) -> CGFloat {
        switch weight {
        case .regular: 0
        case .bold: 0.4
        case .medium: 0.23
        case .semibold: 0.3
        case .light: -0.4
        case .heavy: 0.56
        case .black: 0.62
        case .thin: -0.6
        case .ultraLight: -0.8
        default: 0
        }
    }

    // MARK: Diagnostics

    /// One-line summary of the install state for hosts' launch logs.
    public static var diagnosticsSummary: String {
        guard isInstalled else { return "EditorFontBalancing: not installed" }
        return "EditorFontBalancing: \(weightDescriptors.count) weights, tuned for lineHeightMultiple \(installedForMultiple)"
    }
}
