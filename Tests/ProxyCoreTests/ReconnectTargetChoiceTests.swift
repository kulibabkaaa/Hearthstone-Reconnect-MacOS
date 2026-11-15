import Foundation
import Testing

@testable import ProxyCore

@Suite("Reconnect target choice")
struct ReconnectTargetChoiceTests {
  // Addresses from the reporter's live logs (Asia, 13–15 Nov 2026).
  private let earlierMatch = GameEndpoint(host: "158.115.204.244", port: 1119)
  private let currentMatch = GameEndpoint(host: "158.115.204.233", port: 1119)
  private let battleNet = GameEndpoint(host: "34.64.167.210", port: 1119)
  private let https = GameEndpoint(host: "35.71.159.51", port: 443)

  @Test("keeps the logged address when Hearthstone has it open")
  func loggedAndOpen() {
    let choice = ReconnectTargetChooser.choose(
      logged: [currentMatch], openConnections: [battleNet, currentMatch, https])
    #expect(choice == .loggedAndOpen(currentMatch))
  }

  @Test("an open address logged before the newest one still goes through the network check")
  func olderLoggedAddressStillOpen() {
    let choice = ReconnectTargetChooser.choose(
      logged: [earlierMatch, currentMatch], openConnections: [battleNet, currentMatch])
    #expect(choice == .openGameConnection(currentMatch))
  }

  @Test("finds the current match's server when it was never logged (reporter's case)")
  func currentMatchNotLogged() {
    // Reporter, 15 Nov 2026: newest logged line 09:29 (earlier match), Reconnect pressed 09:52 in a later match
    // whose address was never logged. Open: Battle.net on 1119, the new game server, some HTTPS.
    let choice = ReconnectTargetChooser.choose(
      logged: [earlierMatch], openConnections: [battleNet, currentMatch, https, https])
    #expect(choice == .openGameConnection(currentMatch))
    #expect(choice.endpoint == currentMatch)
  }

  @Test("works with Illia's Europe addresses too")
  func europe() {
    let choice = ReconnectTargetChooser.choose(
      logged: [GameEndpoint(host: "5.42.177.85", port: 1119), GameEndpoint(host: "37.244.26.119", port: 1119)],
      openConnections: [GameEndpoint(host: "34.141.160.181", port: 1119), GameEndpoint(host: "5.42.177.233", port: 1119)]
    )
    #expect(choice == .openGameConnection(GameEndpoint(host: "5.42.177.233", port: 1119)))
  }

  @Test("never closes Battle.net between matches")
  func onlyBattleNetOpen() {
    let choice = ReconnectTargetChooser.choose(logged: [earlierMatch], openConnections: [battleNet, https])
    #expect(choice == .loggedUnchecked(earlierMatch))
  }

  @Test("never picks a connection outside the logged game networks, even if it's the only one left")
  func unknownNetwork() {
    let elsewhere = GameEndpoint(host: "158.115.99.76", port: 1119)
    let choice = ReconnectTargetChooser.choose(logged: [earlierMatch], openConnections: [elsewhere, https])
    #expect(choice == .loggedUnchecked(earlierMatch))
  }

  @Test("does nothing new when two connections are in the game network")
  func ambiguousGameConnections() {
    let other = GameEndpoint(host: "158.115.204.119", port: 1119)  // same /24 as the live one
    let choice = ReconnectTargetChooser.choose(
      logged: [GameEndpoint(host: "158.115.204.1", port: 1119)],
      openConnections: [battleNet, currentMatch, other])
    #expect(choice == .loggedUnchecked(GameEndpoint(host: "158.115.204.1", port: 1119)))
  }

  @Test("three connections on the game port are unclear: falls back")
  func secondBattleNetSocket() {
    let otherBattleNet = GameEndpoint(host: "34.64.12.9", port: 1119)
    let choice = ReconnectTargetChooser.choose(
      logged: [earlierMatch], openConnections: [battleNet, otherBattleNet, currentMatch])
    #expect(choice == .loggedUnchecked(earlierMatch))
  }

  @Test("ignores other ports, private addresses and duplicates")
  func filtering() {
    let choice = ReconnectTargetChooser.choose(
      logged: [earlierMatch],
      openConnections: [
        currentMatch, currentMatch, GameEndpoint(host: "158.115.204.7", port: 443),
        GameEndpoint(host: "192.168.1.8", port: 1119), battleNet,
      ])
    #expect(choice == .openGameConnection(currentMatch))
  }

  @Test("follows the logged port")
  func loggedPort() {
    let oldServer = GameEndpoint(host: "37.244.26.101", port: 3724)
    let choice = ReconnectTargetChooser.choose(
      logged: [GameEndpoint(host: "37.244.26.100", port: 3724)],
      openConnections: [
        oldServer, GameEndpoint(host: "34.141.160.181", port: 3724), GameEndpoint(host: "37.244.26.102", port: 1119),
      ])
    #expect(choice == .openGameConnection(oldServer))
  }

  @Test("behaves like before when Hearthstone's connections can't be read")
  func connectionsUnreadable() {
    #expect(ReconnectTargetChooser.choose(logged: [earlierMatch], openConnections: nil) == .loggedUnchecked(earlierMatch))
    #expect(ReconnectTargetChooser.choose(logged: [earlierMatch], openConnections: []) == .loggedUnchecked(earlierMatch))
  }

  @Test("nothing logged means nothing to recognize the game network by")
  func nothingLogged() {
    #expect(ReconnectTargetChooser.choose(logged: [], openConnections: [battleNet, currentMatch]) == .none)
    #expect(ReconnectTargetChooser.choose(logged: [], openConnections: nil) == .none)
  }

  @Test("network is the first numbers of an IPv4 address")
  func network() {
    #expect(ReconnectTargetChooser.network(of: "158.115.204.233", octets: 3) == "158.115.204")
    #expect(ReconnectTargetChooser.network(of: "158.115.204.233", octets: 2) == "158.115")
    #expect(ReconnectTargetChooser.network(of: "158.115.204", octets: 3) == nil)
    #expect(ReconnectTargetChooser.network(of: "158.115.204.999", octets: 3) == nil)
    #expect(ReconnectTargetChooser.network(of: "eu.actual.battle.net", octets: 3) == nil)
  }

  // Second review, 15 Nov 2026: eu.actual.battle.net resolved to 35.204.191.153, while 35.204.5.248 was a real EU
  // game server, so a /16 rule would have closed Battle.net.
  private let cloudGameServer = GameEndpoint(host: "35.204.5.248", port: 1119)
  private let cloudBattleNet = GameEndpoint(host: "35.204.191.153", port: 1119)

  @Test("never closes Battle.net in the same cloud range as a logged game server, between matches")
  func battleNetNearCloudGameServerBetweenMatches() {
    let choice = ReconnectTargetChooser.choose(logged: [cloudGameServer], openConnections: [cloudBattleNet, https])
    #expect(choice == .loggedUnchecked(cloudGameServer))
  }

  @Test("never closes Battle.net instead of an unlogged game in another range")
  func battleNetNearCloudGameServerDuringMatch() {
    let choice = ReconnectTargetChooser.choose(
      logged: [cloudGameServer],
      openConnections: [cloudBattleNet, GameEndpoint(host: "5.42.177.233", port: 1119), https])
    #expect(choice == .loggedUnchecked(cloudGameServer))
  }

  @Test("refuses a pick when anything else on the port is in its /16")
  func neighbourGuard() {
    let liveCloudGame = GameEndpoint(host: "35.204.5.12", port: 1119)
    let choice = ReconnectTargetChooser.choose(logged: [cloudGameServer], openConnections: [cloudBattleNet, liveCloudGame])
    #expect(choice == .loggedUnchecked(cloudGameServer))
  }

  @Test("a stale socket from an earlier match next to the live one is unclear: falls back")
  func staleSocketNextToLiveGame() {
    let stale = GameEndpoint(host: "158.115.204.200", port: 1119)
    let choice = ReconnectTargetChooser.choose(logged: [earlierMatch, stale], openConnections: [stale, currentMatch])
    #expect(choice == .loggedUnchecked(earlierMatch))
  }

  @Test("documented gap: Battle.net in the /24 of an earlier cloud game server, current match elsewhere")
  func knownGap() {
    // Pinned so any change to it is deliberate. Needs cloud game servers in the player's region; see the doc comment.
    let choice = ReconnectTargetChooser.choose(
      logged: [GameEndpoint(host: "35.204.191.20", port: 1119)],
      openConnections: [cloudBattleNet, GameEndpoint(host: "5.42.177.233", port: 1119)])
    #expect(choice == .openGameConnection(cloudBattleNet))
  }

  @Test("only helps when this session logged a game server in the same /24")
  func differentGameBlock() {
    let choice = ReconnectTargetChooser.choose(
      logged: [GameEndpoint(host: "37.244.26.119", port: 1119)],
      openConnections: [GameEndpoint(host: "34.141.160.181", port: 1119), GameEndpoint(host: "5.42.177.233", port: 1119)])
    #expect(choice == .loggedUnchecked(GameEndpoint(host: "37.244.26.119", port: 1119)))
  }

  @Test("lists logged endpoints newest first, once each")
  func recentEndpoints() {
    let log = """
      I 09:20:00.0000000 Network.GotoGameServe() - address= 158.115.204.233:1119, game=x, client=x, spectateKey=x reconnecting=False
      I 09:27:02.9107040 Network.GotoGameServe() - address= 158.115.204.244:1119, game=x, client=x, spectateKey=x reconnecting=True
      I 09:28:00.0000000 Network.GotoGameServe() - address= 192.168.1.8:1119, game=x
      I 09:29:20.0532150 Network.GotoGameServe() - address= 158.115.204.244:1119, game=x, client=x, spectateKey=x reconnecting=True
      """
    #expect(GameLogEndpointParser.recentEndpoints(in: log) == [earlierMatch, currentMatch])
    #expect(GameLogEndpointParser.recentEndpoints(in: "nothing here").isEmpty)
  }
}
