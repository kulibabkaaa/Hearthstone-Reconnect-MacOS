import Testing

@testable import AppCore

@Suite("Login item repair policy")
struct LoginItemRepairPolicyTests {
  @Test("leaves a running helper alone")
  func runningHelperIsHealthy() {
    var policy = LoginItemRepairPolicy()

    let decision = policy.evaluate(
      registration: .enabled,
      isHelperRunning: true
    )

    #expect(decision == .healthy)
    #expect(policy.repairsStarted == 0)
  }

  @Test(
    "does nothing while the option is off or awaits approval",
    arguments: [
      LoginItemRegistration.notRegistered,
      .notFound,
      .requiresApproval,
    ]
  )
  func inactiveRegistrationIsNotRepaired(
    registration: LoginItemRegistration
  ) {
    var policy = LoginItemRepairPolicy()

    let decision = policy.evaluate(
      registration: registration,
      isHelperRunning: false
    )

    #expect(decision == .notApplicable)
    #expect(policy.repairsStarted == 0)
  }

  @Test("registers again when macOS says enabled but the helper is not running")
  func enabledButNotRunningIsRepaired() {
    var policy = LoginItemRepairPolicy()

    let decision = policy.evaluate(
      registration: .enabled,
      isHelperRunning: false
    )

    #expect(decision == .reregister)
    #expect(policy.repairsStarted == 1)
  }

  @Test("stops once the helper runs after a repair")
  func repairThatWorkedIsHealthy() {
    var policy = LoginItemRepairPolicy()
    _ = policy.evaluate(
      registration: .enabled,
      isHelperRunning: false
    )

    let decision = policy.evaluate(
      registration: .enabled,
      isHelperRunning: true
    )

    #expect(decision == .healthy)
    #expect(policy.repairsStarted == 1)
  }

  @Test("repairs a second time when the first new registration was rejected")
  func rejectedFirstRepairIsRetried() {
    var policy = LoginItemRepairPolicy()
    _ = policy.evaluate(
      registration: .enabled,
      isHelperRunning: false
    )

    let decision = policy.evaluate(
      registration: .enabled,
      isHelperRunning: false
    )

    #expect(decision == .reregister)
    #expect(policy.repairsStarted == 2)
  }

  @Test(
    "registers again when its own registration did not go through",
    arguments: [
      LoginItemRegistration.notRegistered,
      .notFound,
    ]
  )
  func lostRegistrationDuringRepairIsRedone(
    registration: LoginItemRegistration
  ) {
    var policy = LoginItemRepairPolicy()
    _ = policy.evaluate(
      registration: .enabled,
      isHelperRunning: false
    )

    let decision = policy.evaluate(
      registration: registration,
      isHelperRunning: false
    )

    #expect(decision == .reregister)
    #expect(policy.repairsStarted == 2)
  }

  @Test("stops repairing when macOS starts asking for approval")
  func approvalRequestEndsRepair() {
    var policy = LoginItemRepairPolicy()
    _ = policy.evaluate(
      registration: .enabled,
      isHelperRunning: false
    )

    let decision = policy.evaluate(
      registration: .requiresApproval,
      isHelperRunning: false
    )

    #expect(decision == .notApplicable)
    #expect(policy.repairsStarted == 1)
  }

  @Test("gives up after the allowed number of repairs")
  func repairsAreBounded() {
    var policy = LoginItemRepairPolicy()
    for _ in 0..<LoginItemRepairPolicy.maximumRepairs {
      let decision = policy.evaluate(
        registration: .enabled,
        isHelperRunning: false
      )
      #expect(decision == .reregister)
    }

    let decision = policy.evaluate(
      registration: .enabled,
      isHelperRunning: false
    )
    let repeatedDecision = policy.evaluate(
      registration: .enabled,
      isHelperRunning: false
    )

    #expect(decision == .gaveUp)
    #expect(repeatedDecision == .gaveUp)
    #expect(
      policy.repairsStarted
        == LoginItemRepairPolicy.maximumRepairs
    )
  }

  @Test("waits longer than launchd's 10 second retry before checking again")
  func recheckOutlastsLaunchdRetry() {
    #expect(LoginItemRepairPolicy.recheckDelay > 10)
  }
}
