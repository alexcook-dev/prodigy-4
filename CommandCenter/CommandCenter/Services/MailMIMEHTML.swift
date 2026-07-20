import Foundation

/// Extract HTML + binary parts from raw RFC822 (`source of message` from Mail.app).
enum MailMIMEHTML {
    struct PartFile: Sendable, Hashable {
        var filename: String
        var contentID: String? // without <>
        var mimeType: String
        var url: URL
    }

    struct RenderPackage: Sendable {
        var htmlDocument: String
        var plainText: String?
        var baseURL: URL
        var attachments: [PartFile]
        var inlineImages: [PartFile]
    }

    /// Parse `source` bytes, write parts under `workDir`, return HTML document + files.
    static func buildRenderPackage(sourceData: Data, workDir: URL) throws -> RenderPackage {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let source = String(data: sourceData, encoding: .utf8)
            ?? String(data: sourceData, encoding: .isoLatin1)
            ?? ""

        let parts = splitMIMEParts(source)
        var htmlBody: String?
        var plainBody: String?
        var files: [PartFile] = []

        for (index, part) in parts.enumerated() {
            let headers = part.headersLower
            let ctype = headerValue(headers, "content-type") ?? "application/octet-stream"
            let mime = ctype.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }?.lowercased()
                ?? "application/octet-stream"
            let disposition = headerValue(headers, "content-disposition") ?? ""
            let filename = filenameFromHeaders(part.headers)
                ?? (mime.hasPrefix("image/") ? "inline-\(index).\(mime.split(separator: "/").last ?? "bin")" : nil)
            let cid = contentIDFromHeaders(part.headers)
            let encoding = headerValue(headers, "content-transfer-encoding")?.lowercased() ?? ""
            let data = decodeBody(part.body, transferEncoding: encoding)

            if mime == "text/html", htmlBody == nil {
                let charset = charsetFromContentType(ctype)
                htmlBody = decodeText(data, charset: charset)
                continue
            }
            if mime == "text/plain", plainBody == nil {
                let charset = charsetFromContentType(ctype)
                plainBody = decodeText(data, charset: charset)
                continue
            }

            // Skip pure multipart containers
            if mime.hasPrefix("multipart/") { continue }

            // Keep images and named attachments
            let isInlineImage = mime.hasPrefix("image/")
            let isAttachment = disposition.lowercased().contains("attachment") || filename != nil
            guard isInlineImage || isAttachment, let name = filename, !data.isEmpty else { continue }

            let safeName = sanitizeFilename(name)
            let url = uniqueURL(in: workDir, preferred: safeName)
            try data.write(to: url)
            files.append(PartFile(filename: url.lastPathComponent, contentID: cid, mimeType: mime, url: url))
        }

        let htmlCore: String
        if let htmlBody {
            htmlCore = rewriteCIDs(html: htmlBody, parts: files)
        } else if let plainBody {
            htmlCore = wrapPlainAsHTML(plainBody)
        } else {
            htmlCore = "<p><em>(No renderable body)</em></p>"
        }

        let doc = wrapDocument(htmlCore)
        let htmlURL = workDir.appendingPathComponent("message.html")
        try doc.data(using: .utf8)?.write(to: htmlURL)

        let inlines = files.filter { $0.mimeType.hasPrefix("image/") }
        let atts = files.filter { !$0.mimeType.hasPrefix("image/") || ($0.contentID == nil) }
        // Prefer listing non-inline as attachments; still include all files for drag
        let attachmentList = files

        return RenderPackage(
            htmlDocument: doc,
            plainText: plainBody,
            baseURL: workDir,
            attachments: attachmentList,
            inlineImages: inlines
        )
    }

    // MARK: - MIME split

    private struct RawPart {
        var headers: String
        var headersLower: String
        var body: String
    }

    private static func splitMIMEParts(_ source: String) -> [RawPart] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        // Top-level boundary
        guard let boundary = firstBoundary(in: normalized) else {
            // Single part: headers + body
            if let r = normalized.range(of: "\n\n") {
                let h = String(normalized[..<r.lowerBound])
                let b = String(normalized[r.upperBound...])
                return [RawPart(headers: h, headersLower: h.lowercased(), body: b)]
            }
            return [RawPart(headers: "", headersLower: "", body: normalized)]
        }
        return splitByBoundary(normalized, boundary: boundary)
    }

    private static func firstBoundary(in source: String) -> String? {
        let pattern = #"(?im)^Content-Type:.*?boundary=("?)([^";\r\n]+)\1"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              m.numberOfRanges >= 3,
              let r = Range(m.range(at: 2), in: source)
        else { return nil }
        return String(source[r])
    }

    private static func splitByBoundary(_ source: String, boundary: String) -> [RawPart] {
        var parts: [RawPart] = []
        let delim = "--" + boundary
        let chunks = source.components(separatedBy: delim)
        for chunk in chunks {
            var c = chunk
            if c.hasPrefix("--") { continue } // epilogue
            if c.hasPrefix("\n") { c = String(c.dropFirst()) }
            if c.hasSuffix("--\n") || c.hasSuffix("--") { c = String(c.dropLast(c.hasSuffix("--\n") ? 3 : 2)) }
            guard let r = c.range(of: "\n\n") else { continue }
            let headers = String(c[..<r.lowerBound])
            var body = String(c[r.upperBound...])
            // Nested multiparts
            if let nested = firstBoundary(in: headers + "\n\n" + body),
               headers.lowercased().contains("multipart/") {
                parts.append(contentsOf: splitByBoundary(body, boundary: nested))
                // Also keep nested as walk: headers of nested container skipped
                continue
            }
            // Trim trailing boundary noise
            if body.hasSuffix("\n") { body = String(body.dropLast()) }
            parts.append(RawPart(headers: headers, headersLower: headers.lowercased(), body: body))
        }
        // If nested multiparts only, also scan full source for nested boundaries
        if parts.isEmpty {
            // recursive find all boundaries
            let allBounds = matches(source, pattern: #"(?im)boundary=("?)([^";\r\n]+)\1"#)
            for b in allBounds where b != boundary {
                parts.append(contentsOf: splitByBoundary(source, boundary: b))
            }
        }
        return parts
    }

    private static func matches(_ source: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return re.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges >= 3, let r = Range(m.range(at: 2), in: source) else { return nil }
            return String(source[r])
        }
    }

    // MARK: - Decode

    private static func decodeBody(_ body: String, transferEncoding: String) -> Data {
        if transferEncoding.contains("base64") {
            let cleaned = body.components(separatedBy: .whitespacesAndNewlines).joined()
            if let d = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) { return d }
        }
        if transferEncoding.contains("quoted-printable") {
            return Data(decodeQuotedPrintable(body).utf8)
        }
        return Data(body.utf8)
    }

    private static func decodeText(_ data: Data, charset: String) -> String {
        let encoding: String.Encoding
        switch charset.lowercased() {
        case "utf-8", "utf8": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252": encoding = .windowsCP1252
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private static func decodeQuotedPrintable(_ input: String) -> String {
        var output = Data()
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "=" {
                let i1 = input.index(after: i)
                if i1 < input.endIndex {
                    let n = input[i1]
                    if n == "\n" { i = input.index(after: i1); continue }
                    if n == "\r" {
                        i = input.index(after: i1)
                        if i < input.endIndex, input[i] == "\n" { i = input.index(after: i) }
                        continue
                    }
                    let i2 = input.index(after: i1)
                    if i2 <= input.endIndex {
                        let hex = String(input[i1..<i2])
                        if let byte = UInt8(hex, radix: 16) {
                            output.append(byte)
                            i = i2
                            continue
                        }
                    }
                }
            }
            if let v = c.asciiValue { output.append(v) }
            i = input.index(after: i)
        }
        return String(data: output, encoding: .utf8) ?? input
    }

    // MARK: - Headers

    private static func headerValue(_ headersLower: String, _ name: String) -> String? {
        for line in headersLower.components(separatedBy: "\n") {
            if line.hasPrefix(name + ":") {
                return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func filenameFromHeaders(_ headers: String) -> String? {
        let lower = headers
        // filename="..."
        if let re = try? NSRegularExpression(pattern: #"filename\*?=(?:UTF-8''|")?([^\";\r\n]+)"#, options: .caseInsensitive),
           let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r = Range(m.range(at: 1), in: lower) {
            var name = String(lower[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            name = name.removingPercentEncoding ?? name
            return name
        }
        // name="..."
        if let re = try? NSRegularExpression(pattern: #"\bname="?([^\";\r\n]+)"#, options: .caseInsensitive),
           let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r = Range(m.range(at: 1), in: lower) {
            return String(lower[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private static func contentIDFromHeaders(_ headers: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(?im)^Content-ID:\s*<?([^>\r\n]+)>?"#),
              let m = re.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
              let r = Range(m.range(at: 1), in: headers)
        else { return nil }
        return String(headers[r]).trimmingCharacters(in: .whitespaces)
    }

    private static func charsetFromContentType(_ ctype: String) -> String {
        guard let r = ctype.lowercased().range(of: "charset=") else { return "utf-8" }
        var rest = String(ctype[r.upperBound...])
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }).lowercased()
    }

    // MARK: - HTML

    private static func rewriteCIDs(html: String, parts: [PartFile]) -> String {
        var result = html
        // Map cid → file URL
        var map: [String: URL] = [:]
        for p in parts {
            if let cid = p.contentID {
                map[cid.lowercased()] = p.url
                // also filename as cid sometimes used as image001.png@...
                if let at = cid.firstIndex(of: "@") {
                    map[String(cid[..<at]).lowercased()] = p.url
                }
            }
            map[p.filename.lowercased()] = p.url
        }
        guard let re = try? NSRegularExpression(pattern: #"cid:([^"'\s>]+)"#, options: .caseInsensitive) else {
            return result
        }
        let ns = result as NSString
        let matches = re.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            guard let full = Range(m.range(at: 0), in: result),
                  let idr = Range(m.range(at: 1), in: result) else { continue }
            let cid = String(result[idr]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let key = cid.lowercased()
            let url = map[key]
                ?? map[key.components(separatedBy: "@").first ?? key]
            if let url {
                result.replaceSubrange(full, with: url.absoluteString)
            }
        }
        return result
    }

    private static func wrapPlainAsHTML(_ plain: String) -> String {
        let esc = plain
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>\n")
        return "<div style=\"white-space:pre-wrap;font-family:system-ui,sans-serif\">\(esc)</div>"
    }

    private static func wrapDocument(_ body: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        body{font:14px -apple-system,BlinkMacSystemFont,sans-serif;margin:12px;line-height:1.45;word-wrap:break-word;background:transparent;color:#1d1d1f}
        img{max-width:100%;height:auto}
        a{color:#06c}
        table{max-width:100%}
        @media(prefers-color-scheme:dark){body{color:#f5f5f7}a{color:#6cb6ff}}
        </style></head><body>\(body)</body></html>
        """
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return name.components(separatedBy: bad).joined(separator: "_")
    }

    private static func uniqueURL(in dir: URL, preferred: String) -> URL {
        var url = dir.appendingPathComponent(preferred)
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        repeat {
            let n = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            url = dir.appendingPathComponent(n)
            i += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }
}
