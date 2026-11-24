import Foundation

// MARK: - Per-key storage

extension MediaByteRangeStore {
    struct Block: Sendable {
        let offset: Int64
        var data: Data

        var end: Int64 { offset + Int64(data.count) }
    }

    struct Entry: Sendable {
        let contentLength: Int64
        var bootstrapVersion = UUID()
        let residentIncarnation = ResidentIncarnation()
        var bootstrapBaseline: MediaHTTPBootstrapVersionBaseline?
        var blocks: [Block] = []
        var byteCount: Int64 = 0
        var lastReadOffset: Int64 = 0
        var lastUse: UInt64 = 0
        var aheadBudget: Int64 = 0

        init(contentLength: Int64) {
            self.contentLength = contentLength
        }

        var bytesBehindRead: Int64 {
            var total: Int64 = 0
            for block in blocks {
                guard block.offset < lastReadOffset else { break }
                total += min(block.end, lastReadOffset) - block.offset
            }
            return total
        }

        var coalescedRanges: [Range<Int64>] {
            var ranges: [Range<Int64>] = []
            for block in blocks {
                if let last = ranges.last, last.upperBound == block.offset {
                    ranges[ranges.count - 1] = last.lowerBound..<block.end
                } else {
                    ranges.append(block.offset..<block.end)
                }
            }
            return ranges
        }

        func firstIndex(endingAfter offset: Int64) -> Int {
            var low = 0
            var high = blocks.count
            while low < high {
                let mid = (low + high) / 2
                if blocks[mid].end > offset {
                    high = mid
                } else {
                    low = mid + 1
                }
            }
            return low
        }

        func contiguousCount(from offset: Int64) -> Int64 {
            contiguousCount(from: offset, startingAt: firstIndex(endingAfter: offset), maximumCount: .max)
        }

        func contiguousCount(from offset: Int64, startingAt index: Int, maximumCount: Int64) -> Int64 {
            guard index < blocks.count, blocks[index].offset <= offset else { return 0 }
            var cursor = blocks[index].end
            var next = index + 1
            while cursor - offset < maximumCount, next < blocks.count, blocks[next].offset == cursor {
                cursor = blocks[next].end
                next += 1
            }
            return min(cursor - offset, maximumCount)
        }

        func overlaps(_ range: Range<Int64>) -> Bool {
            guard !range.isEmpty, !blocks.isEmpty else { return false }
            let index = firstIndex(endingAfter: range.lowerBound)
            return index < blocks.count && blocks[index].offset < range.upperBound
        }

        func copyPrefix(offset: Int64, count: Int) -> Data? {
            var index = firstIndex(endingAfter: offset)
            guard index < blocks.count, blocks[index].offset <= offset else { return nil }
            let available = contiguousCount(from: offset, startingAt: index, maximumCount: Int64(count))
            let windowEnd = offset + available
            let firstBlock = blocks[index]
            if windowEnd <= firstBlock.end {
                let from = firstBlock.data.startIndex + Int(offset - firstBlock.offset)
                let upTo = firstBlock.data.startIndex + Int(windowEnd - firstBlock.offset)
                return firstBlock.data.subdata(in: from..<upTo)
            }
            var output = Data(capacity: Int(available))
            var cursor = offset
            while cursor < windowEnd {
                let block = blocks[index]
                let from = block.data.startIndex + Int(cursor - block.offset)
                let upTo = block.data.startIndex + Int(min(block.end, windowEnd) - block.offset)
                output.append(block.data[from..<upTo])
                cursor = min(block.end, windowEnd)
                index += 1
            }
            return output
        }

        func overlapByteCount(offset: Int64, end: Int64) -> Int64 {
            guard let last = blocks.last, offset < last.end else { return 0 }
            var total: Int64 = 0
            var index = firstIndex(endingAfter: offset)
            while index < blocks.count, blocks[index].offset < end {
                let block = blocks[index]
                total += max(0, min(end, block.end) - max(offset, block.offset))
                index += 1
            }
            return total
        }

        mutating func dropForAheadCap(excess: Int64, protection: Range<Int64>) {
            let order = blocks.indices.sorted { left, right in
                let lhs = blocks[left]
                let rhs = blocks[right]
                let leftProtected = (lhs.offset..<lhs.end).overlaps(protection)
                let rightProtected = (rhs.offset..<rhs.end).overlaps(protection)
                if leftProtected != rightProtected { return !leftProtected }
                let leftBehind = lhs.end <= protection.lowerBound
                let rightBehind = rhs.end <= protection.lowerBound
                if leftBehind != rightBehind { return leftBehind }
                return leftBehind ? lhs.offset < rhs.offset : lhs.offset > rhs.offset
            }
            var remaining = excess
            var removed: Set<Int> = []
            for index in order where remaining > 0 {
                let block = blocks[index]
                residentIncarnation.revoke(overlapping: block.offset..<block.end)
                let size = Int64(blocks[index].data.count)
                removed.insert(index)
                byteCount -= size
                remaining -= size
            }
            blocks = blocks.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }

        func agrees(with data: Data, at offset: Int64) -> Bool {
            guard let last = blocks.last, offset < last.end else { return true }
            let end = offset + Int64(data.count)
            var index = firstIndex(endingAfter: offset)
            while index < blocks.count, blocks[index].offset < end {
                let block = blocks[index]
                let lower = max(offset, block.offset)
                let upper = min(end, block.end)
                let held = block.data.startIndex + Int(lower - block.offset)
                let incoming = data.startIndex + Int(lower - offset)
                let length = Int(upper - lower)
                guard block.data[held..<held + length] == data[incoming..<incoming + length] else {
                    return false
                }
                index += 1
            }
            return true
        }

        mutating func insertMissing(_ data: Data, at offset: Int64, blockLimit: Int) {
            let end = offset + Int64(data.count)
            if blocks.isEmpty || offset >= blocks[blocks.count - 1].end {
                appendTailGap(offset..<end, of: data, at: offset, blockLimit: blockLimit)
                return
            }
            var gaps: [Range<Int64>] = []
            var cursor = offset
            var index = firstIndex(endingAfter: offset)
            while index < blocks.count, blocks[index].offset < end {
                if blocks[index].offset > cursor {
                    gaps.append(cursor..<blocks[index].offset)
                }
                cursor = max(cursor, blocks[index].end)
                index += 1
            }
            if cursor < end {
                gaps.append(cursor..<end)
            }
            for gap in gaps {
                insertGap(gap, of: data, at: offset, blockLimit: blockLimit)
            }
        }

        private mutating func appendTailGap(
            _ gap: Range<Int64>,
            of data: Data,
            at offset: Int64,
            blockLimit: Int
        ) {
            var cursor = gap.lowerBound
            while cursor < gap.upperBound {
                let from = data.startIndex + Int(cursor - offset)
                let lastIndex = blocks.count - 1
                if lastIndex >= 0,
                   blocks[lastIndex].end == cursor,
                   blocks[lastIndex].data.count < blockLimit {
                    let room = Int64(blockLimit - blocks[lastIndex].data.count)
                    let length = Int(min(room, gap.upperBound - cursor))
                    blocks[lastIndex].data.append(data[from..<from + length])
                    byteCount += Int64(length)
                    cursor += Int64(length)
                    continue
                }
                let length = Int(min(Int64(blockLimit), gap.upperBound - cursor))
                let slice: Data = (from == data.startIndex && length == data.count)
                    ? data
                    : data.subdata(in: from..<from + length)
                blocks.append(Block(offset: cursor, data: slice))
                byteCount += Int64(length)
                cursor += Int64(length)
            }
        }

        private mutating func insertGap(
            _ gap: Range<Int64>,
            of data: Data,
            at offset: Int64,
            blockLimit: Int
        ) {
            var cursor = gap.lowerBound
            while cursor < gap.upperBound {
                let index = firstIndex(endingAfter: cursor)
                let from = data.startIndex + Int(cursor - offset)
                if index > 0, blocks[index - 1].end == cursor, blocks[index - 1].data.count < blockLimit {
                    let room = Int64(blockLimit - blocks[index - 1].data.count)
                    let length = Int(min(room, gap.upperBound - cursor))
                    blocks[index - 1].data.append(data[from..<from + length])
                    byteCount += Int64(length)
                    cursor += Int64(length)
                    continue
                }
                let length = Int(min(Int64(blockLimit), gap.upperBound - cursor))
                blocks.insert(Block(offset: cursor, data: data.subdata(in: from..<from + length)), at: index)
                byteCount += Int64(length)
                cursor += Int64(length)
            }
        }

        mutating func dropFrontBlocks(atMost amount: Int64, endingBy limit: Int64) {
            var remaining = amount
            var dropped = 0
            while dropped < blocks.count {
                let block = blocks[dropped]
                let size = Int64(block.data.count)
                guard size <= remaining, block.end <= limit else { break }
                residentIncarnation.revoke(overlapping: block.offset..<block.end)
                remaining -= size
                byteCount -= size
                dropped += 1
            }
            if dropped > 0 {
                blocks.removeFirst(dropped)
            }
        }
    }
}
