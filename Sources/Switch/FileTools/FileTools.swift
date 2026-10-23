import Foundation

/// The one entry point the queue (and the self-check) use.
enum FileTools {
    /// Runs `op` and returns what it wrote. A file that vanished since it was shelved fails
    /// on its own with `unreadable`.
    static func perform(_ op: FileOperation, inputs: [URL], options: FileToolOptions, cancel: CancelToken,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        guard !inputs.isEmpty else { throw FileToolError.unsupported("No files") }
        for url in inputs where !FileManager.default.isReadableFile(atPath: url.path) {
            throw FileToolError.unreadable(url.lastPathComponent)
        }
        switch op {
        case .convertImage, .compressImage, .resizeImage, .stripMetadata:
            return [try ImageTool.run(op, source: inputs[0], options: options, cancel: cancel)]
        case .compressVideo, .convertVideo, .toAudio:
            return [try await MediaTool.run(op, source: inputs[0], cancel: cancel, progress: progress)]
        case .compressPDF:
            return [try PDFTool.compress(inputs[0], cancel: cancel)]
        case .pdfToImages:
            return [try PDFTool.toImages(inputs[0], cancel: cancel)]
        case .mergePDFs:
            return [try PDFTool.merge(inputs, cancel: cancel)]
        case .imagesToPDF:
            return [try PDFTool.imagesToPDF(inputs, cancel: cancel)]
        case .zip:
            return [try ArchiveTool.zip(inputs, cancel: cancel)]
        case .unzip:
            return [try ArchiveTool.unzip(inputs[0], cancel: cancel)]
        }
    }

    /// Sizes, the keep-only-if-smaller rule, and Settings → Replace the original (the original
    /// goes to the Trash; the result takes its name when the extension matches).
    static func finish(_ op: FileOperation, inputs: [URL], outputs: [URL], replaceOriginal: Bool) throws -> FileOutcome {
        let before = FileSize.of(inputs)
        let after = FileSize.of(outputs)
        if op.mustShrink && after >= before {
            outputs.forEach { try? FileManager.default.removeItem(at: $0) }
            throw FileToolError.alreadyOptimized
        }
        guard replaceOriginal, op.canReplaceOriginal, let original = inputs.first, let output = outputs.first else {
            return FileOutcome(outputs: outputs, bytesBefore: before, bytesAfter: after)
        }
        try FileManager.default.trashItem(at: original, resultingItemURL: nil)
        guard output.pathExtension.lowercased() == original.pathExtension.lowercased() else {
            return FileOutcome(outputs: [output], bytesBefore: before, bytesAfter: after)
        }
        try FileManager.default.moveItem(at: output, to: original)
        return FileOutcome(outputs: [original], bytesBefore: before, bytesAfter: after)
    }
}
