import Foundation

func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 {
        let value = Double(count) / 1_000_000.0
        return String(format: value >= 10 ? "%.0fM" : "%.1fM", value)
    } else if count >= 1_000 {
        let value = Double(count) / 1_000.0
        return String(format: value >= 100 ? "%.0fK" : "%.1fK", value)
    }
    return "\(count)"
}

func formatCost(_ cost: Double) -> String {
    if cost >= 1.0 {
        return String(format: "$%.2f", cost)
    } else if cost >= 0.01 {
        return String(format: "$%.2f", cost)
    } else if cost > 0 {
        return String(format: "$%.3f", cost)
    }
    return "$0.00"
}

func formatRelativeTime(_ timestamp: String) -> String {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    guard let date = isoFormatter.date(from: timestamp) else {
        // Try without fractional seconds
        isoFormatter.formatOptions = [.withInternetDateTime]
        guard let date = isoFormatter.date(from: timestamp) else {
            return ""
        }
        return relativeString(from: date)
    }

    return relativeString(from: date)
}

private func relativeString(from date: Date) -> String {
    let interval = Date().timeIntervalSince(date)

    if interval < 60 { return "just now" }
    if interval < 3600 {
        let mins = Int(interval / 60)
        return "\(mins)m ago"
    }
    if interval < 86400 {
        let hours = Int(interval / 3600)
        return "\(hours)h ago"
    }
    let days = Int(interval / 86400)
    if days == 1 { return "1d ago" }
    if days < 30 { return "\(days)d ago" }
    let months = days / 30
    return "\(months)mo ago"
}

func formatRelativeDate(_ date: Date) -> String {
    let now = Date()
    let interval = now.timeIntervalSince(date)

    if interval < 60 {
        return "just now"
    } else if interval < 3600 {
        let minutes = Int(interval / 60)
        return "\(minutes)m ago"
    } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return "\(hours)h ago"
    } else if interval < 604800 {
        let days = Int(interval / 86400)
        return "\(days)d ago"
    } else {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

func formatFileSize(_ bytes: Int) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        let kb = Double(bytes) / 1024.0
        return String(format: "%.1f KB", kb)
    } else {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}
