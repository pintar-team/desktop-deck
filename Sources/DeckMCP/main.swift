import Foundation
import MCP
import DeckCore

@main struct DeckMCP {
    static func main() async throws {
        let server=Server(name:"desktop-deck",version:"0.3.2",capabilities:.init(tools:.init()))
        let client=UUID().uuidString
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolDefinitions.all.map { definition in
                Tool(name:definition.name,description:definition.description,
                     inputSchema:try! JSONDecoder().decode(Value.self,from:JSONSerialization.data(withJSONObject:definition.schema)))
            })
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let data=try JSONEncoder().encode(params.arguments ?? [:])
                let args=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
                let result=try await Task.detached { try LocalRPC.request(["tool":params.name,"arguments":args,"client":client]) }.value
                var content=[Tool.Content]()
                if let png=result["image"] as? String { content.append(.image(data:png,mimeType:"image/png",annotations:nil,_meta:nil)) }
                var metadata=result; metadata.removeValue(forKey:"image")
                content.append(.text(text:String(decoding:try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]),as:UTF8.self),annotations:nil,_meta:nil))
                return .init(content:content,isError:false)
            } catch { return .init(content:[.text(text:error.localizedDescription,annotations:nil,_meta:nil)],isError:true) }
        }
        try await server.start(transport:StdioTransport())
        await server.waitUntilCompleted()
    }
}
