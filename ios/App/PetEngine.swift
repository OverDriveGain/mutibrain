import SwiftUI
import Combine

/// Mood drives the pet's face + reactions. Purely scripted — no AI here.
enum PetMood {
    case happy, neutral, bored, hungry, sleepy

    var label: String {
        switch self {
        case .happy:   return "Happy"
        case .neutral: return "Okay"
        case .bored:   return "Bored"
        case .hungry:  return "Hungry"
        case .sleepy:  return "Sleepy"
        }
    }
}

/// Tamagotchi-style state machine. Three stats decay over real time; actions
/// (pet / feed / rest / talk) nudge them back up. Persisted across launches so
/// the pet "lived" while the app was closed. Deliberately dumb + deterministic.
final class PetEngine: ObservableObject {
    @Published private(set) var happiness: Double
    @Published private(set) var energy: Double
    @Published private(set) var fullness: Double      // 1 = full, 0 = starving
    @Published var reaction: String? = nil            // transient emoji burst

    private let d = UserDefaults.standard
    private var timer: Timer?

    init() {
        happiness = PetEngine.load("pet.happiness", 0.7)
        energy    = PetEngine.load("pet.energy", 0.8)
        fullness  = PetEngine.load("pet.fullness", 0.7)
        applyDecay()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit { timer?.invalidate() }

    // MARK: - derived mood
    var mood: PetMood {
        if energy < 0.18 { return .sleepy }
        if fullness < 0.25 { return .hungry }
        if happiness > 0.7 { return .happy }
        if happiness < 0.35 { return .bored }
        return .neutral
    }

    // MARK: - actions
    func pet() {
        happiness = clamp(happiness + 0.16)
        energy = clamp(energy - 0.02)
        burst("💗")
        save()
    }

    func feed() {
        fullness = clamp(fullness + 0.4)
        happiness = clamp(happiness + 0.06)
        burst("🍙")
        save()
    }

    func rest() {
        energy = clamp(energy + 0.45)
        burst("💤")
        save()
    }

    /// Called after a voice session with the assistant — engagement cheers it up.
    func talked() {
        happiness = clamp(happiness + 0.22)
        energy = clamp(energy - 0.05)
        burst("✨")
        save()
    }

    // MARK: - time
    private func tick() {
        // gentle live decay so the pet visibly "needs" you over minutes
        happiness = drift(happiness, toward: 0.5, by: 0.01)
        energy = clamp(energy - 0.008)
        fullness = clamp(fullness - 0.012)
        objectWillChange.send()
        save()
    }

    /// Catch up the stats for the wall-clock time the app was closed.
    private func applyDecay() {
        let last = d.double(forKey: "pet.lastSeen")
        guard last > 0 else { return }
        let elapsed = max(0, Date().timeIntervalSince1970 - last)
        let mins = elapsed / 60.0
        energy = clamp(energy - mins * 0.004)
        fullness = clamp(fullness - mins * 0.006)
        happiness = drift(happiness, toward: 0.45, by: min(0.5, mins * 0.003))
    }

    private func save() {
        d.set(happiness, forKey: "pet.happiness")
        d.set(energy, forKey: "pet.energy")
        d.set(fullness, forKey: "pet.fullness")
        d.set(Date().timeIntervalSince1970, forKey: "pet.lastSeen")
    }

    private func burst(_ e: String) {
        reaction = e
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            if self?.reaction == e { self?.reaction = nil }
        }
    }

    // MARK: - helpers
    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
    private func drift(_ v: Double, toward t: Double, by step: Double) -> Double {
        if abs(v - t) <= step { return t }
        return v > t ? v - step : v + step
    }
    private static func load(_ k: String, _ def: Double) -> Double {
        UserDefaults.standard.object(forKey: k) == nil ? def : UserDefaults.standard.double(forKey: k)
    }
}
