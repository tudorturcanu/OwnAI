import Foundation

@main
enum ChatWorkloadCoordinatorRegression {
    static func main() async {
        let first = await ChatWorkloadCoordinator.shared.beginChat()
        let second = await ChatWorkloadCoordinator.shared.beginChat()
        let waiter = Task {
            await ChatWorkloadCoordinator.shared.waitUntilChatIsIdle()
            return true
        }

        try? await Task.sleep(for: .milliseconds(30))
        precondition(!waiter.isCancelled)
        let firstEndedIdle = await ChatWorkloadCoordinator.shared.endChat(first)
        let activeAfterFirst = await ChatWorkloadCoordinator.shared.isChatActive
        let secondEndedIdle = await ChatWorkloadCoordinator.shared.endChat(second)
        let waiterCompleted = await waiter.value
        let activeAtEnd = await ChatWorkloadCoordinator.shared.isChatActive
        precondition(!firstEndedIdle)
        precondition(activeAfterFirst)
        precondition(secondEndedIdle)
        precondition(waiterCompleted)
        precondition(!activeAtEnd)
        print("Chat workload coordinator regression passed")
    }
}
