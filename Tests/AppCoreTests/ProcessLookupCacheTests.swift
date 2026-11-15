import Testing
@testable import AppCore

@Suite("Hearthstone process lookup cache")
struct ProcessLookupCacheTests {
  @Test("looks up on the first request")
  func firstRequest() {
    #expect(ProcessLookupCache().needsLookup(now: 0, cachedIsRunning: false))
  }

  @Test("a running game is reused, poll after poll, for as long as it runs")
  func reuseWhileRunning() {
    var cache = ProcessLookupCache()
    cache.didLookUp(now: 0, found: true)
    for second in stride(from: 0.25, through: 3600, by: 0.25) {
      #expect(!cache.needsLookup(now: second, cachedIsRunning: true))
    }
  }

  @Test("the game quitting or restarting is noticed at the next poll")
  func restart() {
    var cache = ProcessLookupCache()
    cache.didLookUp(now: 0, found: true)
    #expect(cache.needsLookup(now: 0.25, cachedIsRunning: false))
  }

  @Test("a launch or quit notification looks up again at once, found or not")
  func notifications() {
    var cache = ProcessLookupCache()
    cache.didLookUp(now: 0, found: true)
    cache.invalidate()
    #expect(cache.needsLookup(now: 0.25, cachedIsRunning: true))
    cache.didLookUp(now: 0.25, found: false)
    cache.invalidate()
    #expect(cache.needsLookup(now: 0.5, cachedIsRunning: false))
  }

  @Test("with no game running, it looks again only every few seconds (a missed launch notification)")
  func missingRefresh() {
    var cache = ProcessLookupCache()
    cache.didLookUp(now: 100, found: false)
    #expect(!cache.needsLookup(now: 100.25, cachedIsRunning: false))
    #expect(!cache.needsLookup(now: 104.9, cachedIsRunning: false))
    #expect(cache.needsLookup(now: 100 + ProcessLookupCache.missingRefreshInterval, cachedIsRunning: false))
    // A clock that went backwards doesn't freeze the lookup.
    #expect(cache.needsLookup(now: 50, cachedIsRunning: false))
  }
}
