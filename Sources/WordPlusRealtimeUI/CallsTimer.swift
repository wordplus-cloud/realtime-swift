import Foundation

extension Timer {
    /// A timer that fires wherever it was made.
    ///
    /// `Timer.scheduledTimer` installs itself on the *current* thread's run
    /// loop, and a Swift concurrency thread has none — so a timer made from an
    /// `async` function is created, retained, and never fires. That is not a
    /// visible failure: the ring simply never repeats and the watchdog never
    /// bites. Every timer here goes on the main run loop instead, in the common
    /// modes so a scrolling view cannot hold one back.
    static func bmScheduled(every interval: TimeInterval, repeats: Bool, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in body() }

        RunLoop.main.add(timer, forMode: .common)

        return timer
    }

    /// Invalidation belongs to the run loop the timer was installed on, and
    /// these are all on the main one.
    func bmInvalidate() {
        if Thread.isMainThread {
            invalidate()
        } else {
            DispatchQueue.main.async { self.invalidate() }
        }
    }
}
