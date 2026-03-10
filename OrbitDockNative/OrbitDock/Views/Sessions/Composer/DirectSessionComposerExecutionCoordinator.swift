import Foundation

struct DirectSessionComposerExecutionPorts {
  let uploadImages: ([AttachedImage]) async throws -> [ServerImageInput]
  let sendMessage: (ConversationClient.SendMessageRequest) async throws -> Void
  let steerTurn: (ConversationClient.SteerTurnRequest) async throws -> Void
}

enum DirectSessionComposerExecutionCoordinator {
  static func execute(
    _ action: DirectSessionComposerPreparedAction,
    using ports: DirectSessionComposerExecutionPorts
  ) async throws {
    switch action {
      case .blocked, .executeShell:
        return

      case let .steer(request):
        let uploadedImages = try await ports.uploadImages(request.localImages)
        var steerRequest = ConversationClient.SteerTurnRequest(content: request.content)
        steerRequest.images = uploadedImages
        steerRequest.mentions = request.mentions
        try await ports.steerTurn(steerRequest)

      case let .send(request):
        let uploadedImages = try await ports.uploadImages(request.localImages)
        var sendRequest = ConversationClient.SendMessageRequest(content: request.content)
        sendRequest.model = request.model
        sendRequest.effort = request.effort
        sendRequest.skills = request.skills
        sendRequest.images = uploadedImages
        sendRequest.mentions = request.mentions
        try await ports.sendMessage(sendRequest)
    }
  }
}
