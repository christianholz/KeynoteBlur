//
//  ContentView.swift
//  KeynoteBlur
//
//  Created by christian on 9/5/25.
//

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import CryptoKit

final class KeynoteBlurViewModel: ObservableObject {
    static let shared = KeynoteBlurViewModel()

    @Published var originalImage: NSImage? = nil
    @Published var blurRadius: Double = 0
    @Published var hasMaskTemplateAvailable: Bool = false
    @Published var prefersPNGCopy: Bool = false

    private let ciContext = CIContext(options: nil)
    private var lastObservedPasteboardChangeCount: Int = -1

    private let keynoteNativeDataType = NSPasteboard.PasteboardType("com.apple.iWork.TSPNativeData")
    private let keynoteNativeMetadataType = NSPasteboard.PasteboardType("com.apple.iWork.TSPNativeMetadata")
    private let keynoteDescriptionType = NSPasteboard.PasteboardType("com.apple.iWork.TSPDescription")
    private let keynoteHasNativeDrawablesType = NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.hasNativeDrawables")
    private let defaultSlideSize = CGSize(width: 1920, height: 1080)
    private let maxImportedImageSize = CGSize(width: 1920, height: 1080)
    private let maxCopiedImageSlideOccupancy: CGFloat = 0.8

    private init() {
        refreshMaskTemplateAvailability(force: true)
    }

    @discardableResult
    func pasteSlideFromPasteboard() -> Bool {
        let pb = NSPasteboard.general

        if let importedImage = importedImageFromPasteboard(pb) {
            setImportedImage(importedImage.image, prefersPNGCopy: importedImage.prefersPNGCopy)
            return true
        }

        if let url = imageURLFromPasteboardText(pb) {
            Task { [weak self] in
                guard let self,
                      let importedImage = await self.fetchImageFromURL(url) else { return }

                await MainActor.run {
                    self.setImportedImage(
                        importedImage.image,
                        prefersPNGCopy: importedImage.prefersPNGCopy,
                        downsizeToPreviewBounds: true
                    )
                }
            }
            return true
        }

        return false
    }

    func canPasteFromPasteboard() -> Bool {
        let pb = NSPasteboard.general
        return importedImageFromPasteboard(pb) != nil || imageURLFromPasteboardText(pb) != nil
    }

    var processedImage: NSImage? {
        guard let img = originalImage else { return nil }
        let r = blurRadius
        if r <= 0.01 { return img }
        return blurred(image: img, radius: r)
    }

    func copySlideForKeynote() {
        guard let base = processedImage ?? originalImage else { return }

        let imageDisplaySize = displaySizeForCopiedImage(base.size, slideSize: defaultSlideSize)
        let placement = placementGeometry(forImageSize: imageDisplaySize, slideSize: defaultSlideSize)
        let adaptiveFactor = adaptiveScaleFactor(forBlurRadius: blurRadius)
        let finalScaleFactor = adaptiveFactor
        let scaledImage = scaleImage(base, factor: finalScaleFactor)
        guard let mainImageData = encodedCopyData(from: scaledImage, quality: 0.9) else { return }
        let thumbnail = thumbnailImage(from: scaledImage, maxDimension: 256)
        guard let thumbnailData = encodedCopyData(from: thumbnail, quality: 0.8) else { return }


        let pb = NSPasteboard.general

        let showSize = placement.showSize
        let drawableGeometry = placement.geometry

        let dataIdentifier = randomIdentifier()
        let thumbnailDataIdentifier = dataIdentifier + 1
        let mediaStyleIdentifier = randomIdentifier()
        let imageIdentifier = randomIdentifier()
        let captionIdentifier = randomIdentifier()
        let titleIdentifier = randomIdentifier()
        let stylesheetIdentifier = randomIdentifier()
        let nativeStorageIdentifier = randomIdentifier()
        let dataMetadataMapIdentifier = randomIdentifier()
        let pasteboardObjectIdentifier: UInt64 = 51

        let nativeData = KeynotePasteboardEncoder.buildNativeData(
            pasteboardObjectIdentifier: pasteboardObjectIdentifier,
            nativeStorageIdentifier: nativeStorageIdentifier,
            stylesheetIdentifier: stylesheetIdentifier,
            mediaStyleIdentifier: mediaStyleIdentifier,
            imageIdentifier: imageIdentifier,
            titleStandinIdentifier: titleIdentifier,
            captionStandinIdentifier: captionIdentifier,
            imageDataIdentifier: dataIdentifier,
            thumbnailDataIdentifier: thumbnailDataIdentifier,
            imageNaturalSize: CGSize(width: max(1, scaledImage.size.width), height: max(1, scaledImage.size.height)),
            imageDisplaySize: imageDisplaySize,
            showSize: showSize,
            drawableGeometry: drawableGeometry
        )

        let fileExtension = prefersPNGCopy ? "png" : "jpg"
        let digest = Data(Insecure.SHA1.hash(data: mainImageData))
        let thumbDigest = Data(Insecure.SHA1.hash(data: thumbnailData))
        let metadata = KeynotePasteboardEncoder.buildMetadata(
            appName: "com.apple.Keynote 14.5",
            dataMetadataMapIdentifier: dataMetadataMapIdentifier,
            dataEntries: [
                KeynoteMetadataDataEntry(
                    identifier: dataIdentifier,
                    digest: digest,
                    preferredFileName: "KeynoteBlurSlide.\(fileExtension)",
                    fileName: "KeynoteBlurSlide.\(fileExtension)"
                ),
                KeynoteMetadataDataEntry(
                    identifier: thumbnailDataIdentifier,
                    digest: thumbDigest,
                    preferredFileName: "KeynoteBlurSlide-thumb.\(fileExtension)",
                    fileName: "KeynoteBlurSlide-thumb.\(fileExtension)"
                )
            ]
        )

        pb.clearContents()

        _ = pb.setData(mainImageData, forType: iWorkDataType(for: dataIdentifier))
        _ = pb.setData(thumbnailData, forType: iWorkDataType(for: thumbnailDataIdentifier))
        _ = pb.setData(nativeData, forType: keynoteNativeDataType)
        _ = pb.setData(metadata, forType: keynoteNativeMetadataType)
        if let description = makeKeynoteDescriptionPayload() {
            _ = pb.setData(description, forType: keynoteDescriptionType)
        }
        for type in keynoteStateMarkerTypes() {
            _ = pb.setData(Data(), forType: type)
        }
        _ = pb.setData(Data(), forType: keynoteHasNativeDrawablesType)

        refreshMaskTemplateAvailability(force: true)
    }

    func adjustBlurByHorizontalScroll(_ deltaX: CGFloat) {
        let sensitivity: Double = 0.08
        let next = min(100.0, max(0.0, blurRadius + Double(deltaX) * sensitivity))
        guard abs(next - blurRadius) > 0.0001 else { return }
        blurRadius = next
    }

    func refreshMaskTemplateAvailability(force: Bool = false) {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount
        guard force || changeCount != lastObservedPasteboardChangeCount else { return }
        lastObservedPasteboardChangeCount = changeCount

        let available = extractShapeMaskTemplate(from: pb) != nil
        if available != hasMaskTemplateAvailable {
            hasMaskTemplateAvailable = available
        }
    }

    @discardableResult
    func copyMaskedSlideForKeynoteFromTemplate() -> Bool {
        guard let base = processedImage ?? originalImage else { return false }

        let imageDisplaySize = displaySizeForCopiedImage(base.size, slideSize: defaultSlideSize)
        let adaptiveFactor = adaptiveScaleFactor(forBlurRadius: blurRadius)
        let scaledImage = scaleImage(base, factor: adaptiveFactor)
        guard let mainJpegData = jpegData(from: scaledImage, quality: 0.9) else { return false }
        let thumbnail = thumbnailImage(from: scaledImage, maxDimension: 256)
        guard let thumbnailData = jpegData(from: thumbnail, quality: 0.8) else { return false }


        let pb = NSPasteboard.general
        if let imageMaskTemplate = extractImageMaskTemplate(from: pb) {
            copySlideForKeynoteUsingMaskTemplate(
                imageMaskTemplate,
                mainJpegData: mainJpegData,
                thumbnailData: thumbnailData,
                pasteboard: pb
            )
            refreshMaskTemplateAvailability(force: true)
            return true
        }

        if let shapeMaskTemplate = extractShapeMaskTemplate(from: pb) {
            copySlideForKeynoteUsingShapeTemplate(
                shapeMaskTemplate,
                mainJpegData: mainJpegData,
                thumbnailData: thumbnailData,
                imageDisplaySize: imageDisplaySize,
                naturalImageSize: CGSize(width: max(1, scaledImage.size.width), height: max(1, scaledImage.size.height)),
                pasteboard: pb
            )
            refreshMaskTemplateAvailability(force: true)
            return true
        }

        refreshMaskTemplateAvailability(force: true)
        return false
    }

    private struct ImportedImage {
        let image: NSImage
        let prefersPNGCopy: Bool
    }

    private struct ImageMaskTemplate {
        let nativeData: Data
        let descriptionData: Data?
        let stateMarkers: [NSPasteboard.PasteboardType: Data]
        let mainDataIdentifiers: [UInt64]
        let thumbnailDataIdentifiers: [UInt64]
        let maskObjectCount: Int
    }

    private struct ShapeMaskTemplate {
        let descriptionData: Data?
        let stateMarkers: [NSPasteboard.PasteboardType: Data]
        let shapeMaskSources: [ShapeMaskArchiveSource]
    }

    private func extractImageMaskTemplate(from pb: NSPasteboard) -> ImageMaskTemplate? {
        guard let nativeData = pb.data(forType: keynoteNativeDataType) else {
            return nil
        }

        let entries = ProtoArchiveDebugParser.parseArchiveStreamWithPayloads(nativeData)
        let maskObjectCount = entries.filter { $0.type == 3006 }.count
        guard maskObjectCount > 0 else {
            return nil
        }

        var mainDataIdentifiers = Set<UInt64>()
        var thumbnailDataIdentifiers = Set<UInt64>()

        for entry in entries where entry.type == 3005 {
            for identifier in extractDataReferenceIdentifiers(from: entry.messageData, fieldNumber: 11) {
                mainDataIdentifiers.insert(identifier)
            }
            for identifier in extractDataReferenceIdentifiers(from: entry.messageData, fieldNumber: 12) {
                thumbnailDataIdentifiers.insert(identifier)
            }
        }

        guard !mainDataIdentifiers.isEmpty else {
            return nil
        }

        var stateMarkers: [NSPasteboard.PasteboardType: Data] = [:]
        for type in pb.types ?? [] where type.rawValue.hasPrefix("com.apple.iWork.pasteboardState.") {
            stateMarkers[type] = pb.data(forType: type) ?? Data()
        }

        return ImageMaskTemplate(
            nativeData: nativeData,
            descriptionData: pb.data(forType: keynoteDescriptionType),
            stateMarkers: stateMarkers,
            mainDataIdentifiers: mainDataIdentifiers.sorted(),
            thumbnailDataIdentifiers: thumbnailDataIdentifiers.sorted(),
            maskObjectCount: maskObjectCount
        )
    }

    private func extractShapeMaskTemplate(from pb: NSPasteboard) -> ShapeMaskTemplate? {
        guard let nativeData = pb.data(forType: keynoteNativeDataType) else {
            return nil
        }

        let entries = ProtoArchiveDebugParser.parseArchiveStreamWithPayloads(nativeData)
        var shapeMaskSources: [ShapeMaskArchiveSource] = []

        for entry in entries where entry.type == 2011 {
            guard let shapeArchive = extractFirstLengthDelimitedFieldPayload(from: entry.messageData, fieldNumber: 1),
                  let drawableData = extractFirstLengthDelimitedFieldPayload(from: shapeArchive, fieldNumber: 1),
                  let pathSourceData = extractFirstLengthDelimitedFieldPayload(from: shapeArchive, fieldNumber: 3) else {
                continue
            }

            let strippedDrawableData = messageByDroppingFields(drawableData, droppedFields: [10, 11])
            shapeMaskSources.append(
                ShapeMaskArchiveSource(
                    sourceShapeIdentifier: entry.identifier,
                    drawableData: strippedDrawableData,
                    pathSourceData: pathSourceData
                )
            )
        }

        guard !shapeMaskSources.isEmpty else {
            return nil
        }

        var stateMarkers: [NSPasteboard.PasteboardType: Data] = [:]
        for type in pb.types ?? [] where type.rawValue.hasPrefix("com.apple.iWork.pasteboardState.") {
            stateMarkers[type] = pb.data(forType: type) ?? Data()
        }

        return ShapeMaskTemplate(
            descriptionData: pb.data(forType: keynoteDescriptionType),
            stateMarkers: stateMarkers,
            shapeMaskSources: shapeMaskSources
        )
    }

    private func copySlideForKeynoteUsingMaskTemplate(
        _ template: ImageMaskTemplate,
        mainJpegData: Data,
        thumbnailData: Data,
        pasteboard pb: NSPasteboard
    ) {
        let mainDigest = Data(Insecure.SHA1.hash(data: mainJpegData))
        let thumbnailDigest = Data(Insecure.SHA1.hash(data: thumbnailData))
        let dataMetadataMapIdentifier = randomIdentifier()

        let mainIDs = template.mainDataIdentifiers
        let thumbIDs = template.thumbnailDataIdentifiers.filter { !mainIDs.contains($0) }
        var metadataEntries: [KeynoteMetadataDataEntry] = []

        for identifier in mainIDs {
            metadataEntries.append(
                KeynoteMetadataDataEntry(
                    identifier: identifier,
                    digest: mainDigest,
                    preferredFileName: "KeynoteBlurMasked-\(identifier).jpg",
                    fileName: "KeynoteBlurMasked-\(identifier).jpg"
                )
            )
        }
        for identifier in thumbIDs {
            metadataEntries.append(
                KeynoteMetadataDataEntry(
                    identifier: identifier,
                    digest: thumbnailDigest,
                    preferredFileName: "KeynoteBlurMasked-thumb-\(identifier).jpg",
                    fileName: "KeynoteBlurMasked-thumb-\(identifier).jpg"
                )
            )
        }

        let metadata = KeynotePasteboardEncoder.buildMetadata(
            appName: "com.apple.Keynote 14.5",
            dataMetadataMapIdentifier: dataMetadataMapIdentifier,
            dataEntries: metadataEntries
        )

        pb.clearContents()

        for identifier in mainIDs {
            _ = pb.setData(mainJpegData, forType: iWorkDataType(for: identifier))
        }
        for identifier in thumbIDs {
            _ = pb.setData(thumbnailData, forType: iWorkDataType(for: identifier))
        }
        _ = pb.setData(template.nativeData, forType: keynoteNativeDataType)
        _ = pb.setData(metadata, forType: keynoteNativeMetadataType)

        if let descriptionData = template.descriptionData ?? makeKeynoteDescriptionPayload() {
            _ = pb.setData(descriptionData, forType: keynoteDescriptionType)
        }

        if template.stateMarkers.isEmpty {
            for type in keynoteStateMarkerTypes() {
                _ = pb.setData(Data(), forType: type)
            }
            _ = pb.setData(Data(), forType: keynoteHasNativeDrawablesType)
        } else {
            for (type, value) in template.stateMarkers {
                _ = pb.setData(value, forType: type)
            }
            if template.stateMarkers[keynoteHasNativeDrawablesType] == nil {
                _ = pb.setData(Data(), forType: keynoteHasNativeDrawablesType)
            }
        }

        refreshMaskTemplateAvailability(force: true)
    }

    private func copySlideForKeynoteUsingShapeTemplate(
        _ template: ShapeMaskTemplate,
        mainJpegData: Data,
        thumbnailData: Data,
        imageDisplaySize: CGSize,
        naturalImageSize: CGSize,
        pasteboard pb: NSPasteboard
    ) {
        guard !template.shapeMaskSources.isEmpty else {
            return
        }

        let placement = placementGeometry(forImageSize: imageDisplaySize, slideSize: defaultSlideSize)
        let imageDrawableGeometry = placement.geometry

        let dataIdentifier = randomIdentifier()
        let thumbnailDataIdentifier = dataIdentifier + 1
        let mediaStyleIdentifier = randomIdentifier()
        let stylesheetIdentifier = randomIdentifier()
        let nativeStorageIdentifier = randomIdentifier()
        let pasteboardObjectIdentifier: UInt64 = 51
        let dataMetadataMapIdentifier = randomIdentifier()

        let maskedPayload = KeynotePasteboardEncoder.buildNativeDataUsingShapeMasks(
            pasteboardObjectIdentifier: pasteboardObjectIdentifier,
            nativeStorageIdentifier: nativeStorageIdentifier,
            stylesheetIdentifier: stylesheetIdentifier,
            mediaStyleIdentifier: mediaStyleIdentifier,
            imageDataIdentifier: dataIdentifier,
            thumbnailDataIdentifier: thumbnailDataIdentifier,
            imageNaturalSize: naturalImageSize,
            imageDisplaySize: imageDisplaySize,
            showSize: placement.showSize,
            imageDrawableGeometry: imageDrawableGeometry,
            shapeMasks: template.shapeMaskSources,
            identifierFactory: { randomIdentifier() }
        )

        let mainDigest = Data(Insecure.SHA1.hash(data: mainJpegData))
        let thumbDigest = Data(Insecure.SHA1.hash(data: thumbnailData))
        let metadata = KeynotePasteboardEncoder.buildMetadata(
            appName: "com.apple.Keynote 14.5",
            dataMetadataMapIdentifier: dataMetadataMapIdentifier,
            dataEntries: [
                KeynoteMetadataDataEntry(
                    identifier: dataIdentifier,
                    digest: mainDigest,
                    preferredFileName: "KeynoteBlurMaskedSlide.jpg",
                    fileName: "KeynoteBlurMaskedSlide.jpg"
                ),
                KeynoteMetadataDataEntry(
                    identifier: thumbnailDataIdentifier,
                    digest: thumbDigest,
                    preferredFileName: "KeynoteBlurMaskedSlide-thumb.jpg",
                    fileName: "KeynoteBlurMaskedSlide-thumb.jpg"
                )
            ]
        )

        pb.clearContents()

        _ = pb.setData(mainJpegData, forType: iWorkDataType(for: dataIdentifier))
        _ = pb.setData(thumbnailData, forType: iWorkDataType(for: thumbnailDataIdentifier))
        _ = pb.setData(maskedPayload.nativeData, forType: keynoteNativeDataType)
        _ = pb.setData(metadata, forType: keynoteNativeMetadataType)

        if let descriptionData = makeKeynoteDescriptionPayload(drawableCount: maskedPayload.imageIdentifiers.count) {
            _ = pb.setData(descriptionData, forType: keynoteDescriptionType)
        } else if let fallbackDescription = template.descriptionData {
            _ = pb.setData(fallbackDescription, forType: keynoteDescriptionType)
        }

        for type in keynoteStateMarkerTypes(drawableCount: maskedPayload.imageIdentifiers.count) {
            _ = pb.setData(Data(), forType: type)
        }
        _ = pb.setData(Data(), forType: keynoteHasNativeDrawablesType)

        refreshMaskTemplateAvailability(force: true)
    }

    private func extractDataReferenceIdentifiers(from messageData: Data, fieldNumber: Int) -> [UInt64] {
        extractLengthDelimitedFieldPayloads(from: messageData, fieldNumber: fieldNumber).compactMap {
            extractReferenceIdentifier(from: $0)
        }
    }

    private func extractFirstLengthDelimitedFieldPayload(from messageData: Data, fieldNumber: Int) -> Data? {
        extractLengthDelimitedFieldPayloads(from: messageData, fieldNumber: fieldNumber).first
    }

    private func extractLengthDelimitedFieldPayloads(from messageData: Data, fieldNumber: Int) -> [Data] {
        var cursor = ProtoArchiveDebugCursor(data: messageData)
        var payloads: [Data] = []

        while cursor.hasRemaining {
            guard let key = cursor.readVarint() else { break }
            let field = Int(key >> 3)
            let wire = key & 0x7

            if wire == PBWireType.lengthDelimited.rawValue {
                guard let len = cursor.readVarint(),
                      let data = cursor.readData(count: Int(len)) else {
                    break
                }
                if field == fieldNumber {
                    payloads.append(data)
                }
                continue
            }

            if !cursor.skipField(wireType: wire) {
                break
            }
        }

        return payloads
    }

    private func extractReferenceIdentifier(from messageData: Data) -> UInt64? {
        var cursor = ProtoArchiveDebugCursor(data: messageData)

        while cursor.hasRemaining {
            guard let key = cursor.readVarint() else { break }
            let field = Int(key >> 3)
            let wire = key & 0x7

            if field == 1, wire == PBWireType.varint.rawValue {
                return cursor.readVarint()
            }

            if !cursor.skipField(wireType: wire) {
                break
            }
        }

        return nil
    }

    private func messageByDroppingFields(_ messageData: Data, droppedFields: Set<Int>) -> Data {
        var cursor = ProtoArchiveDebugCursor(data: messageData)
        var out = ProtoWriter()

        while cursor.hasRemaining {
            guard let key = cursor.readVarint() else { break }
            let field = Int(key >> 3)
            let wire = key & 0x7

            switch wire {
            case PBWireType.varint.rawValue:
                guard let value = cursor.readVarint() else { return out.data }
                if !droppedFields.contains(field) {
                    out.writeUInt64(fieldNumber: field, value: value)
                }
            case PBWireType.fixed64.rawValue:
                guard let value = cursor.readData(count: 8) else { return out.data }
                if !droppedFields.contains(field) {
                    out.writeFixed64Bytes(fieldNumber: field, value: value)
                }
            case PBWireType.lengthDelimited.rawValue:
                guard let len = cursor.readVarint(),
                      let value = cursor.readData(count: Int(len)) else {
                    return out.data
                }
                if !droppedFields.contains(field) {
                    out.writeBytes(fieldNumber: field, value: value)
                }
            case PBWireType.fixed32.rawValue:
                guard let value = cursor.readData(count: 4) else { return out.data }
                if !droppedFields.contains(field) {
                    out.writeFixed32Bytes(fieldNumber: field, value: value)
                }
            default:
                return out.data
            }
        }

        return out.data
    }

    private func randomIdentifier() -> UInt64 {
        UInt64.random(in: 2_500_000...9_000_000)
    }

    // MARK: - Image Ops

    private func importedImageFromPasteboard(_ pb: NSPasteboard) -> ImportedImage? {
        let pngType = NSPasteboard.PasteboardType(UTType.png.identifier)
        if let data = pb.data(forType: pngType), let importedImage = importedImage(from: data) {
            return importedImage
        }

        let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        if let data = pb.data(forType: jpegType), let importedImage = importedImage(from: data) {
            return importedImage
        }

        if let data = pb.data(forType: .tiff), let image = NSImage(data: data) {
            return ImportedImage(image: image, prefersPNGCopy: false)
        }

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            return ImportedImage(image: image, prefersPNGCopy: false)
        }

        return nil
    }

    private func importedImage(from data: Data) -> ImportedImage? {
        guard let image = NSImage(data: data) else { return nil }
        let prefersPNGCopy = isPNGData(data) && hasTransparentCornerPixel(in: data)
        return ImportedImage(image: image, prefersPNGCopy: prefersPNGCopy)
    }

    private func isPNGData(_ data: Data) -> Bool {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return data.starts(with: pngSignature)
    }

    private func hasTransparentCornerPixel(in data: Data) -> Bool {
        guard let rep = NSBitmapImageRep(data: data) else { return false }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0, rep.hasAlpha else { return false }

        let cornerPoints = [
            (x: 0, y: 0),
            (x: width - 1, y: 0),
            (x: 0, y: height - 1),
            (x: width - 1, y: height - 1)
        ]

        return cornerPoints.contains { point in
            guard let color = rep.colorAt(x: point.x, y: point.y) else { return false }
            return color.alphaComponent < 0.999
        }
    }

    private func displaySizeForCopiedImage(_ imageSize: CGSize, slideSize: CGSize) -> CGSize {
        let clampedImageSize = CGSize(
            width: max(1, imageSize.width),
            height: max(1, imageSize.height)
        )
        let maxDisplaySize = CGSize(
            width: max(1, slideSize.width * maxCopiedImageSlideOccupancy),
            height: max(1, slideSize.height * maxCopiedImageSlideOccupancy)
        )

        guard clampedImageSize.width > slideSize.width || clampedImageSize.height > slideSize.height else {
            return clampedImageSize
        }

        let factor = min(
            maxDisplaySize.width / clampedImageSize.width,
            maxDisplaySize.height / clampedImageSize.height
        )
        return CGSize(
            width: max(1, clampedImageSize.width * factor),
            height: max(1, clampedImageSize.height * factor)
        )
    }

    private func placementGeometry(forImageSize imageSize: CGSize, slideSize: CGSize) -> (showSize: CGSize, geometry: KeynotePBGeometry) {
        let clampedImageSize = CGSize(
            width: max(1, imageSize.width),
            height: max(1, imageSize.height)
        )
        let showSize = CGSize(
            width: max(slideSize.width, clampedImageSize.width),
            height: max(slideSize.height, clampedImageSize.height)
        )
        let originX = max(0, (showSize.width - clampedImageSize.width) / 2)
        let originY = max(0, (showSize.height - clampedImageSize.height) / 2)
        let geometry = KeynotePBGeometry(
            x: Float(originX),
            y: Float(originY),
            width: Float(clampedImageSize.width),
            height: Float(clampedImageSize.height),
            flags: 3,
            angle: 0
        )
        return (showSize, geometry)
    }

    private func setImportedImage(_ image: NSImage, prefersPNGCopy: Bool, downsizeToPreviewBounds: Bool = false) {
        blurRadius = 0
        originalImage = downsizeToPreviewBounds ? downsizeIfNeeded(image, maxSize: maxImportedImageSize) : image
        self.prefersPNGCopy = prefersPNGCopy
    }

    private func imageURLFromPasteboardText(_ pb: NSPasteboard) -> URL? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first,
           isFetchableURL(first) {
            return first
        }

        let candidateTypes: [NSPasteboard.PasteboardType] = [
            .string,
            NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
            NSPasteboard.PasteboardType(UTType.plainText.identifier)
        ]

        for type in candidateTypes {
            guard let raw = pb.string(forType: type) else { continue }
            let trimmed = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard !trimmed.isEmpty else { continue }

            if let direct = URL(string: trimmed), isFetchableURL(direct) {
                return direct
            }

            if !trimmed.contains("://"),
               let assumedHTTPS = URL(string: "https://\(trimmed)"),
               isFetchableURL(assumedHTTPS) {
                return assumedHTTPS
            }
        }

        return nil
    }

    private func isFetchableURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    private func fetchImageFromURL(_ url: URL) async -> ImportedImage? {
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            return importedImage(from: data)
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        request.setValue("KeynoteBlur", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        return importedImage(from: data)
    }

    private func downsizeIfNeeded(_ image: NSImage, maxSize: CGSize) -> NSImage {
        let width = max(1, image.size.width)
        let height = max(1, image.size.height)
        let factor = min(1.0, min(maxSize.width / width, maxSize.height / height))
        guard factor < 1.0 else { return image }
        return bicubicScaleImage(image, factor: factor) ?? scaleImage(image, factor: factor)
    }

    private func bicubicScaleImage(_ image: NSImage, factor: CGFloat) -> NSImage? {
        guard factor > 0,
              let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff),
              let filter = CIFilter(name: "CIBicubicScaleTransform") else {
            return nil
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(factor, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        filter.setValue(0.0, forKey: "inputB")
        filter.setValue(0.75, forKey: "inputC")

        guard let output = filter.outputImage else { return nil }

        let targetSize = CGSize(
            width: max(1, floor(ciImage.extent.width * factor)),
            height: max(1, floor(ciImage.extent.height * factor))
        )
        let targetRect = CGRect(origin: .zero, size: targetSize)
        let cropped = output.cropped(to: targetRect)

        guard let cgImage = ciContext.createCGImage(cropped, from: targetRect) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: targetSize.width, height: targetSize.height))
    }

    private func blurred(image: NSImage, radius: Double) -> NSImage {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else {
            return image
        }
        let filter = CIFilter.gaussianBlur()
        filter.radius = Float(radius)
        filter.inputImage = ci.clampedToExtent()
        guard let output = filter.outputImage?.cropped(to: ci.extent),
              let cgImage = ciContext.createCGImage(output, from: ci.extent) else {
            return image
        }
        let size = NSSize(width: ci.extent.width, height: ci.extent.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    private func scaleImage(_ image: NSImage, factor: CGFloat) -> NSImage {
        guard factor > 0 else { return image }
        let newSize = NSSize(width: max(1, image.size.width * factor), height: max(1, image.size.height * factor))
        let out = NSImage(size: newSize)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
    }

    private func adaptiveScaleFactor(forBlurRadius radius: Double) -> CGFloat {
        // Inverse-root falloff: blur 12 -> ~0.71, 24 -> ~0.45, 48 -> ~0.24.
        // Clamped to 1/8x so highly blurred images still keep enough detail.
        let r = max(0.0, radius)
        let raw = 1.0 / sqrt(1.0 + pow(r / 12.0, 2.0))
        let clamped = max(0.125, min(1.0, raw))
        return CGFloat(clamped)
    }

    private func jpegData(from image: NSImage, quality: CGFloat) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    private func encodedCopyData(from image: NSImage, quality: CGFloat) -> Data? {
        prefersPNGCopy ? pngData(from: image) : jpegData(from: image, quality: quality)
    }

    private func thumbnailImage(from image: NSImage, maxDimension: CGFloat) -> NSImage {
        let w = max(1, image.size.width)
        let h = max(1, image.size.height)
        let longest = max(w, h)
        let factor = min(1.0, maxDimension / longest)
        return scaleImage(image, factor: factor)
    }

    private func persistImageDataToTempFile(_ data: Data, fileExtension: String) -> String? {
        let fileName = "keynoteblur-\(UUID().uuidString).\(fileExtension)"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    private func iWorkDataType(for identifier: UInt64) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType("com.apple.iWork.TSPData.\(identifier)")
    }

    private func keynoteStateMarkerTypes(drawableCount: Int = 1) -> [NSPasteboard.PasteboardType] {
        let count = max(1, drawableCount)
        var types: [NSPasteboard.PasteboardType] = []
        if count == 1 {
            types.append(NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.hasSingleNativeImageDrawable"))
        }
        types.append(NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.numberOfDrawables-\(count)"))
        types.append(NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.numberOfTopLevelDrawables-\(count)"))
        types.append(NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.drawableInfoKinds-1"))
        types.append(NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.hasOnlyNativeImageDrawableInfos"))
        types.append(NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.countOfObject-2"))
        types.append(NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.hasNativeTypes"))
        types.append(NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.maxinlinenestingdepth-1"))
        types.append(NSPasteboard.PasteboardType("com.apple.iWork.pasteboardState.elementKinds-1"))
        return types
    }

    private func makeKeynoteDescriptionPayload(drawableCount: Int = 1) -> Data? {
        let count = max(1, drawableCount)
        let imageDrawableDescriptor: [String: Any] = [
            "anchoredToText": 0,
            "class": "TSDImageInfo",
            "elementKind": 1,
            "floatingAboveText": 1,
            "inlineWithText": 0,
            "maxInlineNestingDepth": 1
        ]
        let payload: [String: Any] = [
            "nativeObj": ["KNPasteboardNativeStorage": 1],
            "drawables": Array(repeating: imageDrawableDescriptor, count: count)
        ]
        return try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
    }

}

private enum PBWireType: UInt64 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

private struct ProtoWriter {
    private(set) var data = Data()

    mutating func writeKey(fieldNumber: Int, wireType: PBWireType) {
        writeVarint((UInt64(fieldNumber) << 3) | wireType.rawValue)
    }

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while true {
            if v < 0x80 {
                data.append(UInt8(v))
                return
            }
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
    }

    mutating func writeUInt64(fieldNumber: Int, value: UInt64) {
        writeKey(fieldNumber: fieldNumber, wireType: .varint)
        writeVarint(value)
    }

    mutating func writeUInt32(fieldNumber: Int, value: UInt32) {
        writeUInt64(fieldNumber: fieldNumber, value: UInt64(value))
    }

    mutating func writeBool(fieldNumber: Int, value: Bool) {
        writeUInt64(fieldNumber: fieldNumber, value: value ? 1 : 0)
    }

    mutating func writeFloat(fieldNumber: Int, value: Float) {
        writeKey(fieldNumber: fieldNumber, wireType: .fixed32)
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { raw in
            data.append(raw.bindMemory(to: UInt8.self))
        }
    }

    mutating func writeFixed32Bytes(fieldNumber: Int, value: Data) {
        guard value.count == 4 else { return }
        writeKey(fieldNumber: fieldNumber, wireType: .fixed32)
        data.append(value)
    }

    mutating func writeFixed64Bytes(fieldNumber: Int, value: Data) {
        guard value.count == 8 else { return }
        writeKey(fieldNumber: fieldNumber, wireType: .fixed64)
        data.append(value)
    }

    mutating func writeBytes(fieldNumber: Int, value: Data) {
        writeKey(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeString(fieldNumber: Int, value: String) {
        writeBytes(fieldNumber: fieldNumber, value: Data(value.utf8))
    }

    mutating func writeMessage(fieldNumber: Int, messageData: Data) {
        writeBytes(fieldNumber: fieldNumber, value: messageData)
    }

    mutating func writePackedUInt32(fieldNumber: Int, values: [UInt32]) {
        guard !values.isEmpty else { return }

        var packed = ProtoWriter()
        for value in values {
            packed.writeVarint(UInt64(value))
        }

        writeKey(fieldNumber: fieldNumber, wireType: .lengthDelimited)
        writeVarint(UInt64(packed.data.count))
        data.append(packed.data)
    }
}

private struct ProtoArchiveDebugEntry {
    let identifier: UInt64
    let type: UInt32
    let messageLength: Int
}

private struct ProtoArchivePayloadEntry {
    let identifier: UInt64
    let type: UInt32
    let messageData: Data
}

private struct ProtoArchiveDebugCursor {
    let data: Data
    var index: Int = 0

    var hasRemaining: Bool { index < data.count }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while index < data.count {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift

            if (byte & 0x80) == 0 {
                return result
            }

            shift += 7
            if shift > 63 { return nil }
        }

        return nil
    }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0, index + count <= data.count else { return nil }
        let out = data.subdata(in: index..<(index + count))
        index += count
        return out
    }

    mutating func skipField(wireType: UInt64) -> Bool {
        switch wireType {
        case 0:
            return readVarint() != nil
        case 1:
            return readData(count: 8) != nil
        case 2:
            guard let len = readVarint() else { return false }
            return readData(count: Int(len)) != nil
        case 5:
            return readData(count: 4) != nil
        default:
            return false
        }
    }
}

private enum ProtoArchiveDebugParser {
    static func parseArchiveStream(_ data: Data) -> [ProtoArchiveDebugEntry] {
        parseArchiveStreamWithPayloads(data).map {
            ProtoArchiveDebugEntry(
                identifier: $0.identifier,
                type: $0.type,
                messageLength: $0.messageData.count
            )
        }
    }

    static func parseArchiveStreamWithPayloads(_ data: Data) -> [ProtoArchivePayloadEntry] {
        var cursor = ProtoArchiveDebugCursor(data: data)
        var entries: [ProtoArchivePayloadEntry] = []

        while cursor.hasRemaining {
            guard let archiveInfoLen = cursor.readVarint(),
                  let archiveInfoData = cursor.readData(count: Int(archiveInfoLen)) else {
                break
            }

            let info = parseArchiveInfo(archiveInfoData)
            guard let messageData = cursor.readData(count: info.messageLength) else {
                break
            }

            entries.append(
                ProtoArchivePayloadEntry(
                    identifier: info.identifier,
                    type: info.type,
                    messageData: messageData
                )
            )
        }

        return entries
    }

    private static func parseArchiveInfo(_ data: Data) -> (identifier: UInt64, type: UInt32, messageLength: Int) {
        var cursor = ProtoArchiveDebugCursor(data: data)
        var identifier: UInt64 = 0
        var messageType: UInt32 = 0
        var messageLength: Int = 0

        while cursor.hasRemaining {
            guard let key = cursor.readVarint() else { break }
            let field = Int(key >> 3)
            let wire = key & 0x7

            if field == 1, wire == 0 {
                identifier = cursor.readVarint() ?? 0
                continue
            }

            if field == 2, wire == 2 {
                guard let len = cursor.readVarint(),
                      let messageInfoData = cursor.readData(count: Int(len)) else {
                    break
                }
                let parsed = parseMessageInfo(messageInfoData)
                messageType = parsed.type
                messageLength = parsed.length
                continue
            }

            if !cursor.skipField(wireType: wire) {
                break
            }
        }

        return (identifier, messageType, messageLength)
    }

    private static func parseMessageInfo(_ data: Data) -> (type: UInt32, length: Int) {
        var cursor = ProtoArchiveDebugCursor(data: data)
        var type: UInt32 = 0
        var length: Int = 0

        while cursor.hasRemaining {
            guard let key = cursor.readVarint() else { break }
            let field = Int(key >> 3)
            let wire = key & 0x7

            if field == 1, wire == 0 {
                type = UInt32(cursor.readVarint() ?? 0)
                continue
            }
            if field == 3, wire == 0 {
                length = Int(cursor.readVarint() ?? 0)
                continue
            }

            if !cursor.skipField(wireType: wire) {
                break
            }
        }

        return (type, length)
    }
}

private struct KeynotePBGeometry {
    let x: Float
    let y: Float
    let width: Float
    let height: Float
    let flags: UInt32
    let angle: Float
}

private struct ShapeMaskArchiveSource {
    let sourceShapeIdentifier: UInt64
    let drawableData: Data
    let pathSourceData: Data
}

private struct KeynoteMaskedNativePayload {
    let nativeData: Data
    let imageIdentifiers: [UInt64]
    let maskIdentifiers: [UInt64]
}

private struct ArchiveEntry {
    let identifier: UInt64
    let type: UInt32
    let messageData: Data
}

private struct KeynoteMetadataDataEntry {
    let identifier: UInt64
    let digest: Data
    let preferredFileName: String
    let fileName: String
}

private enum KeynotePasteboardEncoder {
    static func buildNativeData(
        pasteboardObjectIdentifier: UInt64,
        nativeStorageIdentifier: UInt64,
        stylesheetIdentifier: UInt64,
        mediaStyleIdentifier: UInt64,
        imageIdentifier: UInt64,
        titleStandinIdentifier: UInt64,
        captionStandinIdentifier: UInt64,
        imageDataIdentifier: UInt64,
        thumbnailDataIdentifier: UInt64,
        imageNaturalSize: CGSize,
        imageDisplaySize: CGSize,
        showSize: CGSize,
        drawableGeometry: KeynotePBGeometry
    ) -> Data {
        let stylesheet = makeStylesheetArchive(styleIdentifier: mediaStyleIdentifier)
        let mediaStyle = makeMediaStyleArchive()
        let imageArchive = makeImageArchive(
            geometry: drawableGeometry,
            styleIdentifier: mediaStyleIdentifier,
            dataIdentifier: imageDataIdentifier,
            thumbnailDataIdentifier: thumbnailDataIdentifier,
            originalSize: imageDisplaySize,
            naturalSize: imageNaturalSize,
            titleIdentifier: titleStandinIdentifier,
            captionIdentifier: captionStandinIdentifier,
            maskIdentifier: nil
        )
        let pasteboardObject = makePasteboardObject(
            drawableIdentifier: imageIdentifier,
            nativeStorageIdentifier: nativeStorageIdentifier,
            stylesheetIdentifier: stylesheetIdentifier
        )
        let nativeStorage = makeNativeStorage(
            drawableIdentifier: imageIdentifier,
            showSize: showSize,
            drawableGeometry: drawableGeometry
        )

        let entries: [ArchiveEntry] = [
            ArchiveEntry(identifier: pasteboardObjectIdentifier, type: 11000, messageData: pasteboardObject),
            ArchiveEntry(identifier: imageIdentifier, type: 3005, messageData: imageArchive),
            ArchiveEntry(identifier: captionStandinIdentifier, type: 3097, messageData: Data()),
            ArchiveEntry(identifier: titleStandinIdentifier, type: 3097, messageData: Data()),
            ArchiveEntry(identifier: mediaStyleIdentifier, type: 3016, messageData: mediaStyle),
            ArchiveEntry(identifier: nativeStorageIdentifier, type: 11, messageData: nativeStorage),
            ArchiveEntry(identifier: stylesheetIdentifier, type: 401, messageData: stylesheet),
        ]

        return makeArchiveStream(entries: entries)
    }

    static func buildNativeDataUsingShapeMasks(
        pasteboardObjectIdentifier: UInt64,
        nativeStorageIdentifier: UInt64,
        stylesheetIdentifier: UInt64,
        mediaStyleIdentifier: UInt64,
        imageDataIdentifier: UInt64,
        thumbnailDataIdentifier: UInt64,
        imageNaturalSize: CGSize,
        imageDisplaySize: CGSize,
        showSize: CGSize,
        imageDrawableGeometry: KeynotePBGeometry,
        shapeMasks: [ShapeMaskArchiveSource],
        identifierFactory: () -> UInt64
    ) -> KeynoteMaskedNativePayload {
        let stylesheet = makeStylesheetArchive(styleIdentifier: mediaStyleIdentifier)
        let mediaStyle = makeMediaStyleArchive()

        var entries: [ArchiveEntry] = []
        var imageIdentifiers: [UInt64] = []
        var maskIdentifiers: [UInt64] = []

        for shapeMask in shapeMasks {
            let imageIdentifier = identifierFactory()
            let maskIdentifier = identifierFactory()
            let captionStandinIdentifier = identifierFactory()
            let titleStandinIdentifier = identifierFactory()

            let imageArchive = makeImageArchive(
                geometry: imageDrawableGeometry,
                styleIdentifier: mediaStyleIdentifier,
                dataIdentifier: imageDataIdentifier,
                thumbnailDataIdentifier: thumbnailDataIdentifier,
                originalSize: imageDisplaySize,
                naturalSize: imageNaturalSize,
                titleIdentifier: titleStandinIdentifier,
                captionIdentifier: captionStandinIdentifier,
                maskIdentifier: maskIdentifier
            )
            let maskArchive = makeMaskArchive(
                drawableData: shapeMask.drawableData,
                pathSourceData: shapeMask.pathSourceData
            )

            imageIdentifiers.append(imageIdentifier)
            maskIdentifiers.append(maskIdentifier)
            entries.append(ArchiveEntry(identifier: imageIdentifier, type: 3005, messageData: imageArchive))
            entries.append(ArchiveEntry(identifier: captionStandinIdentifier, type: 3097, messageData: Data()))
            entries.append(ArchiveEntry(identifier: titleStandinIdentifier, type: 3097, messageData: Data()))
            entries.append(ArchiveEntry(identifier: maskIdentifier, type: 3006, messageData: maskArchive))
        }

        let pasteboardObject = makePasteboardObject(
            drawableIdentifiers: imageIdentifiers,
            nativeStorageIdentifier: nativeStorageIdentifier,
            stylesheetIdentifier: stylesheetIdentifier
        )
        let nativeStorage = makeNativeStorage(
            drawableIdentifiers: imageIdentifiers,
            showSize: showSize,
            drawableGeometries: Array(repeating: imageDrawableGeometry, count: imageIdentifiers.count)
        )

        let fullEntries = [ArchiveEntry(identifier: pasteboardObjectIdentifier, type: 11000, messageData: pasteboardObject)] +
            entries +
            [
                ArchiveEntry(identifier: mediaStyleIdentifier, type: 3016, messageData: mediaStyle),
                ArchiveEntry(identifier: nativeStorageIdentifier, type: 11, messageData: nativeStorage),
                ArchiveEntry(identifier: stylesheetIdentifier, type: 401, messageData: stylesheet)
            ]

        return KeynoteMaskedNativePayload(
            nativeData: makeArchiveStream(entries: fullEntries),
            imageIdentifiers: imageIdentifiers,
            maskIdentifiers: maskIdentifiers
        )
    }

    static func buildMetadata(
        appName: String,
        dataMetadataMapIdentifier: UInt64,
        dataEntries: [KeynoteMetadataDataEntry]
    ) -> Data {
        let metadata = makePasteboardMetadata(
            appName: appName,
            dataMetadataMapIdentifier: dataMetadataMapIdentifier,
            dataEntries: dataEntries
        )

        let entries: [ArchiveEntry] = [
            ArchiveEntry(identifier: 52, type: 11007, messageData: metadata),
            ArchiveEntry(identifier: dataMetadataMapIdentifier, type: 11015, messageData: makeDataMetadataMap())
        ]

        return makeArchiveStream(entries: entries)
    }

    private static func makeArchiveStream(entries: [ArchiveEntry]) -> Data {
        var out = Data()

        for entry in entries {
            let archiveInfo = makeArchiveInfo(identifier: entry.identifier, type: entry.type, messageLength: entry.messageData.count)
            var sizeWriter = ProtoWriter()
            sizeWriter.writeVarint(UInt64(archiveInfo.count))
            out.append(sizeWriter.data)
            out.append(archiveInfo)
            out.append(entry.messageData)
        }

        return out
    }

    private static func makeArchiveInfo(identifier: UInt64, type: UInt32, messageLength: Int) -> Data {
        var messageInfo = ProtoWriter()
        messageInfo.writeUInt32(fieldNumber: 1, value: type)
        messageInfo.writeUInt32(fieldNumber: 3, value: UInt32(messageLength))

        var archiveInfo = ProtoWriter()
        archiveInfo.writeUInt64(fieldNumber: 1, value: identifier)
        archiveInfo.writeMessage(fieldNumber: 2, messageData: messageInfo.data)
        return archiveInfo.data
    }

    private static func makeReference(_ identifier: UInt64) -> Data {
        var w = ProtoWriter()
        w.writeUInt64(fieldNumber: 1, value: identifier)
        return w.data
    }

    private static func makeDataReference(_ identifier: UInt64) -> Data {
        var w = ProtoWriter()
        w.writeUInt64(fieldNumber: 1, value: identifier)
        return w.data
    }

    private static func makePoint(x: Float, y: Float) -> Data {
        var w = ProtoWriter()
        w.writeFloat(fieldNumber: 1, value: x)
        w.writeFloat(fieldNumber: 2, value: y)
        return w.data
    }

    private static func makeSize(width: Float, height: Float) -> Data {
        var w = ProtoWriter()
        w.writeFloat(fieldNumber: 1, value: width)
        w.writeFloat(fieldNumber: 2, value: height)
        return w.data
    }

    private static func makeGeometry(_ geometry: KeynotePBGeometry) -> Data {
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 1, messageData: makePoint(x: geometry.x, y: geometry.y))
        w.writeMessage(fieldNumber: 2, messageData: makeSize(width: geometry.width, height: geometry.height))
        w.writeUInt32(fieldNumber: 3, value: geometry.flags)
        w.writeFloat(fieldNumber: 4, value: geometry.angle)
        return w.data
    }

    private static func makeDrawableArchive(
        geometry: KeynotePBGeometry,
        titleIdentifier: UInt64,
        captionIdentifier: UInt64
    ) -> Data {
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 1, messageData: makeGeometry(geometry))
        w.writeMessage(fieldNumber: 3, messageData: makeExteriorTextWrapArchive())
        w.writeBool(fieldNumber: 5, value: false)
        w.writeBool(fieldNumber: 7, value: true)
        w.writeMessage(fieldNumber: 10, messageData: makeReference(titleIdentifier))
        w.writeMessage(fieldNumber: 11, messageData: makeReference(captionIdentifier))
        w.writeBool(fieldNumber: 12, value: false)
        w.writeBool(fieldNumber: 13, value: false)
        return w.data
    }

    private static func makeExteriorTextWrapArchive() -> Data {
        var w = ProtoWriter()
        w.writeUInt32(fieldNumber: 1, value: 4)
        w.writeUInt32(fieldNumber: 2, value: 2)
        w.writeUInt32(fieldNumber: 3, value: 1)
        w.writeFloat(fieldNumber: 4, value: 12.0)
        w.writeFloat(fieldNumber: 5, value: 0.5)
        w.writeBool(fieldNumber: 6, value: false)
        return w.data
    }

    private static func makeStyleArchive() -> Data {
        var w = ProtoWriter()
        w.writeString(fieldNumber: 2, value: "image-0-imageStyle")
        return w.data
    }

    private static func makeMediaStylePropertiesArchive() -> Data {
        var properties = ProtoWriter()
        properties.writeMessage(fieldNumber: 1, messageData: makeStrokeArchive())
        properties.writeFloat(fieldNumber: 2, value: 1.0)
        properties.writeMessage(fieldNumber: 3, messageData: makeShadowArchive())
        properties.writeMessage(fieldNumber: 4, messageData: Data()) // reflection
        return properties.data
    }

    private static func makeColorBlack() -> Data {
        var w = ProtoWriter()
        w.writeUInt32(fieldNumber: 1, value: 1) // rgb
        w.writeFloat(fieldNumber: 3, value: 0.0)
        w.writeFloat(fieldNumber: 4, value: 0.0)
        w.writeFloat(fieldNumber: 5, value: 0.0)
        w.writeFloat(fieldNumber: 6, value: 1.0)
        w.writeUInt32(fieldNumber: 12, value: 1) // srgb
        return w.data
    }

    private static func makeStrokePatternArchive() -> Data {
        var w = ProtoWriter()
        w.writeUInt32(fieldNumber: 1, value: 2) // TSDEmptyPattern
        w.writeFloat(fieldNumber: 2, value: 0.0) // phase
        w.writeUInt32(fieldNumber: 3, value: 0) // count
        // Keep explicit zero pattern entries to mirror Keynote payload shape.
        w.writeFloat(fieldNumber: 4, value: 0.0)
        w.writeFloat(fieldNumber: 4, value: 0.0)
        w.writeFloat(fieldNumber: 4, value: 0.0)
        w.writeFloat(fieldNumber: 4, value: 0.0)
        w.writeFloat(fieldNumber: 4, value: 0.0)
        w.writeFloat(fieldNumber: 4, value: 0.0)
        return w.data
    }

    private static func makeStrokeArchive() -> Data {
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 1, messageData: makeColorBlack())
        w.writeFloat(fieldNumber: 2, value: 1.0)
        w.writeUInt32(fieldNumber: 3, value: 0) // butt cap
        w.writeUInt32(fieldNumber: 4, value: 0) // miter join
        w.writeFloat(fieldNumber: 5, value: 4.0)
        w.writeMessage(fieldNumber: 6, messageData: makeStrokePatternArchive())
        return w.data
    }

    private static func makeShadowArchive() -> Data {
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 1, messageData: makeColorBlack())
        w.writeFloat(fieldNumber: 2, value: 315.0)
        w.writeFloat(fieldNumber: 3, value: 5.0)
        w.writeUInt32(fieldNumber: 4, value: 1)
        w.writeFloat(fieldNumber: 5, value: 1.0)
        w.writeBool(fieldNumber: 6, value: false)
        w.writeUInt32(fieldNumber: 7, value: 0)
        return w.data
    }

    private static func makeMediaStyleArchive() -> Data {
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 1, messageData: makeStyleArchive())
        w.writeUInt32(fieldNumber: 10, value: 4)
        w.writeMessage(fieldNumber: 11, messageData: makeMediaStylePropertiesArchive())
        return w.data
    }

    private static func makeStylesheetArchive(styleIdentifier: UInt64) -> Data {
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 1, messageData: makeReference(styleIdentifier))
        var identifiedEntry = ProtoWriter()
        identifiedEntry.writeString(fieldNumber: 1, value: "image-0-imageStyle")
        identifiedEntry.writeMessage(fieldNumber: 2, messageData: makeReference(styleIdentifier))
        w.writeMessage(fieldNumber: 2, messageData: identifiedEntry.data)
        w.writeBool(fieldNumber: 4, value: false)
        return w.data
    }

    private static func makeImageArchive(
        geometry: KeynotePBGeometry,
        styleIdentifier: UInt64,
        dataIdentifier: UInt64,
        thumbnailDataIdentifier: UInt64,
        originalSize: CGSize,
        naturalSize: CGSize,
        titleIdentifier: UInt64,
        captionIdentifier: UInt64,
        maskIdentifier: UInt64?
    ) -> Data {
        let drawable = makeDrawableArchive(geometry: geometry, titleIdentifier: titleIdentifier, captionIdentifier: captionIdentifier)
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 1, messageData: drawable)
        w.writeMessage(fieldNumber: 3, messageData: makeReference(styleIdentifier))
        w.writeMessage(fieldNumber: 4, messageData: makeSize(width: Float(originalSize.width), height: Float(originalSize.height)))
        if let maskIdentifier {
            w.writeMessage(fieldNumber: 5, messageData: makeReference(maskIdentifier))
        }
        w.writeUInt32(fieldNumber: 7, value: 0)
        w.writeMessage(fieldNumber: 9, messageData: makeSize(width: Float(naturalSize.width), height: Float(naturalSize.height)))
        w.writeMessage(fieldNumber: 11, messageData: makeDataReference(dataIdentifier))
        w.writeMessage(fieldNumber: 12, messageData: makeDataReference(thumbnailDataIdentifier))
        w.writeBool(fieldNumber: 18, value: false)
        return w.data
    }

    private static func makePasteboardObject(
        drawableIdentifier: UInt64,
        nativeStorageIdentifier: UInt64,
        stylesheetIdentifier: UInt64
    ) -> Data {
        makePasteboardObject(
            drawableIdentifiers: [drawableIdentifier],
            nativeStorageIdentifier: nativeStorageIdentifier,
            stylesheetIdentifier: stylesheetIdentifier
        )
    }

    private static func makePasteboardObject(
        drawableIdentifiers: [UInt64],
        nativeStorageIdentifier: UInt64,
        stylesheetIdentifier: UInt64
    ) -> Data {
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 1, messageData: makeReference(stylesheetIdentifier))
        for drawableIdentifier in drawableIdentifiers {
            w.writeMessage(fieldNumber: 2, messageData: makeReference(drawableIdentifier))
        }
        w.writeMessage(fieldNumber: 6, messageData: makeReference(nativeStorageIdentifier))
        return w.data
    }

    private static func makeNativeStorage(
        drawableIdentifier: UInt64,
        showSize: CGSize,
        drawableGeometry: KeynotePBGeometry
    ) -> Data {
        makeNativeStorage(
            drawableIdentifiers: [drawableIdentifier],
            showSize: showSize,
            drawableGeometries: [drawableGeometry]
        )
    }

    private static func makeNativeStorage(
        drawableIdentifiers: [UInt64],
        showSize: CGSize,
        drawableGeometries: [KeynotePBGeometry]
    ) -> Data {
        var w = ProtoWriter()
        for drawableIdentifier in drawableIdentifiers {
            w.writeMessage(fieldNumber: 1, messageData: makeReference(drawableIdentifier))
        }
        w.writeMessage(fieldNumber: 5, messageData: makeSize(width: Float(showSize.width), height: Float(showSize.height)))
        if drawableGeometries.isEmpty {
            w.writeMessage(
                fieldNumber: 7,
                messageData: makeGeometry(
                    KeynotePBGeometry(
                        x: 0,
                        y: 0,
                        width: Float(showSize.width),
                        height: Float(showSize.height),
                        flags: 3,
                        angle: 0
                    )
                )
            )
        } else {
            for geometry in drawableGeometries {
                w.writeMessage(fieldNumber: 7, messageData: makeGeometry(geometry))
            }
        }
        w.writeString(fieldNumber: 8, value: UUID().uuidString.uppercased())
        w.writeBool(fieldNumber: 16, value: false)
        return w.data
    }

    private static func makeMaskArchive(drawableData: Data, pathSourceData: Data) -> Data {
        var w = ProtoWriter()
        w.writeMessage(fieldNumber: 1, messageData: drawableData)
        w.writeMessage(fieldNumber: 2, messageData: pathSourceData)
        return w.data
    }

    private static func makeDataInfo(_ entry: KeynoteMetadataDataEntry) -> Data {
        var w = ProtoWriter()
        w.writeUInt64(fieldNumber: 1, value: entry.identifier)
        w.writeBytes(fieldNumber: 2, value: entry.digest)
        w.writeString(fieldNumber: 3, value: entry.preferredFileName)
        w.writeString(fieldNumber: 4, value: entry.fileName)
        return w.data
    }

    private static func makePasteboardMetadata(
        appName: String,
        dataMetadataMapIdentifier: UInt64,
        dataEntries: [KeynoteMetadataDataEntry]
    ) -> Data {
        var w = ProtoWriter()
        w.writePackedUInt32(fieldNumber: 1, values: [14, 4, 1])
        w.writeString(fieldNumber: 2, value: appName)
        for entry in dataEntries {
            w.writeMessage(fieldNumber: 3, messageData: makeDataInfo(entry))
        }
        w.writeMessage(fieldNumber: 6, messageData: makeReference(dataMetadataMapIdentifier))
        w.writePackedUInt32(fieldNumber: 7, values: [2, 0, 0])
        return w.data
    }

    private static func makeDataMetadataMap() -> Data {
        Data()
    }
}

struct ContentView: View {
    @StateObject private var vm = KeynoteBlurViewModel.shared
    @StateObject private var optionKeyMonitor = OptionKeyMonitor()
    private let pasteboardPollTimer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    private var shouldUseMaskedCopy: Bool {
        optionKeyMonitor.isOptionPressed && vm.hasMaskTemplateAvailable
    }

    private var copyButtonTitle: String {
        shouldUseMaskedCopy ? "copy masked image to clipboard" : "copy \(vm.prefersPNGCopy ? "PNG" : "JPG") to clipboard"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("blur:")
                Slider(value: $vm.blurRadius, in: 0...100)
            }

            Group {
                if let img = vm.processedImage ?? vm.originalImage {
                    GeometryReader { geo in
                        let avail = geo.size
                        let imgSize = img.size
                        let fitScale = min(avail.width / max(imgSize.width, 1), avail.height / max(imgSize.height, 1))
                        let scale = min(1.0, fitScale)
                        let drawW = imgSize.width * scale
                        let drawH = imgSize.height * scale

                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: drawW, height: drawH)
                            .overlay(
                                HorizontalTrackpadScrollCaptureView { deltaX in
                                    vm.adjustBlurByHorizontalScroll(deltaX)
                                }
                            )
                            .frame(width: avail.width, height: avail.height, alignment: .center)
                    }
                } else {
                    ZStack {
                        Color(NSColor.windowBackgroundColor)
                        Text("paste a slide from the clipboard to show a preview")
                            .foregroundColor(.secondary)
                    }
                    .frame(minHeight: 260)
                }
            }

            HStack(spacing: 8) {
                Button("paste from clipboard") {
                    _ = vm.pasteSlideFromPasteboard()
                }

                Spacer()

                Button(copyButtonTitle) {
                    if shouldUseMaskedCopy {
                        _ = vm.copyMaskedSlideForKeynoteFromTemplate()
                    } else {
                        vm.copySlideForKeynote()
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(vm.originalImage == nil)
            }
        }
        .padding(16)
        .onAppear {
            vm.refreshMaskTemplateAvailability(force: true)
        }
        .onReceive(pasteboardPollTimer) { _ in
            vm.refreshMaskTemplateAvailability()
        }
        .onChange(of: optionKeyMonitor.isOptionPressed) { _, _ in
            vm.refreshMaskTemplateAvailability(force: true)
        }
    }
}

private struct HorizontalTrackpadScrollCaptureView: NSViewRepresentable {
    let onHorizontalScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> HorizontalTrackpadScrollCaptureNSView {
        let view = HorizontalTrackpadScrollCaptureNSView()
        view.onHorizontalScroll = onHorizontalScroll
        return view
    }

    func updateNSView(_ nsView: HorizontalTrackpadScrollCaptureNSView, context: Context) {
        nsView.onHorizontalScroll = onHorizontalScroll
    }
}

private final class HorizontalTrackpadScrollCaptureNSView: NSView {
    var onHorizontalScroll: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        if abs(deltaX) > 0.01, abs(deltaX) >= abs(deltaY) {
            onHorizontalScroll?(deltaX)
            return
        }

        super.scrollWheel(with: event)
    }
}

final class OptionKeyMonitor: ObservableObject {
    @Published var isOptionPressed: Bool = NSEvent.modifierFlags.contains(.option)
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var appObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    init() {
        refreshState()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.isOptionPressed = event.modifierFlags.contains(.option)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            DispatchQueue.main.async {
                self?.isOptionPressed = event.modifierFlags.contains(.option)
            }
        }

        let center = NotificationCenter.default
        appObservers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshState()
            }
        )
        appObservers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.isOptionPressed = false
            }
        )

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        pollTimer?.invalidate()
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refreshState() {
        let pressed = NSEvent.modifierFlags.contains(.option)
        if pressed != isOptionPressed {
            isOptionPressed = pressed
        }
    }
}
