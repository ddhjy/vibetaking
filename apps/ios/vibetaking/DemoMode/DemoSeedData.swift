import Foundation

enum DemoSeedData {
    static let polishWorkflowID = UUID(uuidString: "6a1c0d2e-4b73-4f1a-9d88-2f0c6e1a7b10")!
    static let inboxWorkflowID = UUID(uuidString: "2f8e91aa-0c44-4d6b-8a11-9c3e5d7f2012")!
    static let archiveWorkflowID = UUID(uuidString: "9d4b22c1-71ae-4e08-bf55-18a0c3d94670")!
    static let saveWorkflowID = UUID(uuidString: "c0b17e54-3a29-4f80-91dd-6e4a8b2c1357")!
    static let macWorkflowID = UUID(uuidString: "e7a5d130-8f2c-4b19-a063-5d1c9e84b2aa")!
    static let sessionID = UUID(uuidString: "3c9f1d80-6a2e-4b47-91c0-0d8e5a7b4f21")!

    static func seed(into rootURL: URL, defaults: UserDefaults) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let now = Date.now
        seedNotes(into: rootURL, now: now)
        seedDraft(into: rootURL, now: now)
        seedSkill(into: rootURL)
        seedMemory(into: rootURL, now: now)
        seedSession(into: rootURL, now: now)
        seedWorkflows(defaults: defaults)
    }

    private static func seedNotes(into rootURL: URL, now: Date) {
        let notes: [(offset: TimeInterval, text: String, tags: [String])] = [
            (
                -90,
                "下午茶时忽然想到：主页的键盘应该在打开的一瞬间就就绪，想法不能在解锁动画里溜走。",
                ["灵感"]
            ),
            (
                -2 * 3600,
                """
                产品评审纪要
                - 演示模式只切数据集和配置组，真实记录完全不动
                - 历史页要看得出标签、搜索和统计，截图才立得住
                - 设置里的开关必须藏得住，又要关得掉
                - 下周一对一下截图顺序：主页、历史、标签、Workflow、Agent
                """,
                ["工作"]
            ),
            (
                -5 * 3600,
                """
                晚上买菜
                - 番茄
                - 鸡蛋
                - 青菜
                - 豆腐
                - 记得带上帆布袋
                """,
                ["生活", "待办"]
            ),
            (
                -22 * 3600,
                "整理书架时翻到一本旧笔记本。字很乱，但那几页比后来工整的文档更像自己。",
                ["生活", "灵感"]
            ),
            (
                -26 * 3600,
                """
                读书摘录：《把想法先抓住》
                速记工具不该要求你先分类、先起标题、先决定这则想法值不值得留下。分类是事后的整理，不是入场券。真正稀缺的是那两分钟的完整注意力——如果写下之前还要做选择，想法就已经在菜单里冷却了。好的工具先接住，再慢慢长出结构。标签、搜索、工作流都该服务于事后的重逢，而不是挡住当下的那一行字。
                """,
                ["读书"]
            ),
            (
                -30 * 3600,
                "跟设计对了一轮标签筛选。多选、排除、无标签这三项同时出现时，筛选条才像真的在用，而不是摆设。",
                ["工作"]
            ),
            (
                -3 * 24 * 3600,
                "周会：演示数据集按「今天 / 昨天 / 本周 / 上月」铺开，这样相对时间、分组和统计都会自然好看。",
                ["工作"]
            ),
            (
                -3 * 24 * 3600 - 3600,
                "跑步到江边时冒出来的一句：记录不是为了更忙，是为了回头时还能认出来。",
                ["生活", "灵感"]
            ),
            (
                -4 * 24 * 3600,
                """
                截图前检查
                - [ ] 主页留半截草稿
                - [ ] 历史里能看到多种标签
                - [ ] Workflow 工具栏不少于三个按钮
                - [ ] Skills 列表不是空的
                - [ ] Agent 里有一条完整对话
                """,
                ["待办", "工作"]
            ),
            (
                -4 * 24 * 3600 - 1800,
                "钥匙放在门口抽屉第二层。",
                []
            ),
            (
                -5 * 24 * 3600,
                "让 Agent 把会议纪要压成三段：结论、未决、下一步。比自己对着录音回忆要快。",
                ["工作"]
            ),
            (
                -6 * 24 * 3600,
                "想给设置页加一个只有自己找得到的开关。连点版本号，刚好够藏，又不至于忘。",
                ["灵感"]
            ),
            (
                -10 * 24 * 3600,
                "摘录：先写下来，意义会在重读时自己长出来。很多时候不是当时没想清楚，是当时不该要求想清楚。",
                ["读书"]
            ),
            (
                -11 * 24 * 3600,
                "周末沿着河堤走到旧桥再折返，大约四十分钟。下次带上耳机，只听风。",
                ["生活"]
            ),
            (
                -12 * 24 * 3600,
                "技术备忘：记录就是带 front matter 的 Markdown。文件名是时间，标签写在 YAML 里，iCloud Drive 同步整份目录。",
                ["工作"]
            ),
            (
                -28 * 24 * 3600,
                "第一次把草稿做成打开即写。没有列表，没有欢迎页，打开就是键盘。从那天起，这个应用才像自己会用的东西。",
                ["灵感", "工作"]
            ),
            (
                -30 * 24 * 3600,
                """
                关于速记工具的一点想法
                我越来越相信，笔记软件输给的不是功能，而是开始写之前的摩擦。新建、命名、选笔记本、选模板，每多一步，就有一个念头选择不留下。随心记把这件事收成「打开、写下、离开」。标签可以后补，润色可以交给 Workflow，整理可以交给 Agent。先把句子保住，系统再慢慢长出结构——这比一个完美的知识库首页更接近真实生活。生活里的想法很少预约，它们只在走路、排队、会议间隙出现，也只愿意停留几秒。
                """,
                ["读书", "灵感"]
            ),
            (
                -32 * 24 * 3600,
                "妈妈生日是下个月 12 号。记得提前一周订蛋糕，不要再变成当天现找。",
                ["生活", "待办"]
            ),
            (
                -35 * 24 * 3600,
                "下雨了，窗没关。",
                []
            ),
            (
                -36 * 24 * 3600,
                """
                本月想做完
                - 把演示数据写成一套可重复播种的样本
                - 历史页统计看起来像有人在用
                - App Store 截图不再借用真实记录
                """,
                ["工作", "待办"]
            ),
        ]

        var usedNames = Set<String>()
        for note in notes {
            var createdAt = now.addingTimeInterval(note.offset)
            var name = fileName(for: createdAt)
            while usedNames.contains(name) {
                createdAt = createdAt.addingTimeInterval(1)
                name = fileName(for: createdAt)
            }
            usedNames.insert(name)

            let content = markdown(
                text: note.text,
                tags: note.tags,
                createdAt: createdAt
            )
            let url = rootURL.appendingPathComponent(name)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func seedDraft(into rootURL: URL, now: Date) {
        let text = "下周一演示，截图顺序先排一下：主页、历史、标签"
        let content = markdown(text: text, tags: [], createdAt: now)
        let url = rootURL.appendingPathComponent("_draft.md")
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func seedSkill(into rootURL: URL) {
        let skillDir = rootURL
            .appendingPathComponent("_skills", isDirectory: true)
            .appendingPathComponent("weekly-report", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

        let body = """
        ---
        name: 周报整理
        description: 把近期记录整理成结构清晰的周报，适合演示 Agent 与 Skills。
        version: 1.0.0
        ---

        # 周报整理

        当用户要求写周报、汇总本周进展或整理工作记录时使用。

        1. 先用笔记或文件工具读取本周相关记录，不要凭空编造。
        2. 按「进展 / 问题 / 下一步」三段输出，每段用短句，避免空话。
        3. 能对应到具体记录的结论优先保留原文里的事实。
        4. 最后给出一个可直接粘贴到聊天或文档里的版本。
        """
        try? body.write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func seedMemory(into rootURL: URL, now: Date) {
        let memoryDir = rootURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        let global = """
        # 全局记忆

        - 用户用「随心记」随手记下灵感和工作要点，不喜欢先分类再动笔。
        - 偏好简洁、可执行的输出，不要客套和空话。
        - 常用标签：灵感、工作、读书、生活、待办。
        - 演示和截图必须使用独立数据，不要出现真实人名、公司或私人行程。
        """
        try? global.write(
            to: memoryDir.appendingPathComponent("GLOBAL.md"),
            atomically: true,
            encoding: .utf8
        )

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let daily = """
        <!-- \(stampFormatter.string(from: yesterday)) -->
        ## 演示偏好

        截图时优先展示历史列表、带标签的记录，以及主页里写到一半的草稿。Workflow 工具栏保持多个按钮可见。
        """
        try? daily.write(
            to: memoryDir.appendingPathComponent("\(dayFormatter.string(from: yesterday)).md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func seedSession(into rootURL: URL, now: Date) {
        let sessionsDir = rootURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let createdAt = now.addingTimeInterval(-3 * 3600)
        let inputJSON = #"{"path":"_skills/weekly-report/SKILL.md","tool_title":"读取周报技能"}"#
        let session = AgentChatSession(
            id: sessionID,
            title: "帮我整理这周的周报",
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: [
                StoredAgentMessage(
                    role: "user",
                    parts: [
                        StoredAgentPart(kind: .text, text: "帮我把这周的工作整理成周报")
                    ]
                ),
                StoredAgentMessage(
                    role: "assistant",
                    parts: [
                        StoredAgentPart(
                            kind: .toolUse,
                            toolId: "call_weekly_report",
                            toolName: "file_read",
                            inputJSON: inputJSON
                        ),
                        StoredAgentPart(
                            kind: .toolResult,
                            toolId: "call_weekly_report",
                            toolName: "file_read",
                            content: "已读取 _skills/weekly-report/SKILL.md：按进展 / 问题 / 下一步整理。",
                            isError: false
                        ),
                        StoredAgentPart(
                            kind: .text,
                            text: """
                            这是根据本周记录整理的周报：

                            ## 进展
                            - 演示模式改成整组切换数据集和配置，真实记录完全隔离
                            - 历史、标签、Workflow、Agent 都补了适合截图的样本

                            ## 问题
                            - 设置里的开关要藏住，关掉之后还得找得到入口

                            ## 下一步
                            - 按主页、历史、标签、Workflow、Agent 的顺序出截图
                            """
                        )
                    ]
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        let url = sessionsDir.appendingPathComponent("\(sessionID.uuidString).json")
        try? data.write(to: url, options: .atomic)
    }

    private static func seedWorkflows(defaults: UserDefaults) {
        let workflows = [
            Workflow(
                id: polishWorkflowID,
                name: "润色文案",
                icon: "sparkles",
                kind: .manual,
                isOpen: true,
                nodes: [
                    WorkflowNode(
                        type: .aiProcess,
                        config: WorkflowNode.NodeConfig(
                            aiPrompt: "把下面的文字润色得更清晰、简洁，保持原意，只输出润色后的正文。"
                        )
                    ),
                    WorkflowNode(type: .copyToClipboard)
                ]
            ),
            Workflow(
                id: inboxWorkflowID,
                name: "整理待办",
                icon: "checklist",
                kind: .manual,
                isOpen: true,
                nodes: [
                    WorkflowNode(
                        type: .agentProcess,
                        config: WorkflowNode.NodeConfig(
                            agentPrompt: "把输入整理成清晰的待办清单，合并重复项，按优先级排序。只输出清单。"
                        )
                    )
                ]
            ),
            Workflow(
                id: archiveWorkflowID,
                name: "摘要归档",
                icon: "text.badge.star",
                kind: .manual,
                isOpen: false,
                nodes: [
                    WorkflowNode(
                        type: .aiProcess,
                        config: WorkflowNode.NodeConfig(
                            aiPrompt: "用两三句话概括下面的内容，保留关键信息，不要添加原文没有的事实。"
                        )
                    ),
                    WorkflowNode(type: .save)
                ]
            ),
            Workflow(
                id: saveWorkflowID,
                name: "快速保存",
                icon: "square.and.arrow.down",
                kind: .manual,
                isOpen: false,
                nodes: [
                    WorkflowNode(type: .save)
                ]
            ),
            Workflow(
                id: macWorkflowID,
                name: "发到 Mac",
                icon: "laptopcomputer",
                kind: .manual,
                isOpen: false,
                syncConfig: Workflow.SyncConfig(host: "localhost", port: 7788),
                nodes: [
                    WorkflowNode(
                        type: .httpPost,
                        config: WorkflowNode.NodeConfig(
                            httpHost: "localhost",
                            httpPort: 7788
                        )
                    )
                ]
            )
        ]

        if let data = try? JSONEncoder().encode(workflows) {
            defaults.set(data, forKey: "workflows_v2")
        }
        defaults.set(polishWorkflowID.uuidString, forKey: "selectedWorkflowId")
        defaults.set(true, forKey: "agentMemoryEnabled")
    }

    private static func markdown(text: String, tags: [String], createdAt: Date) -> String {
        var content = "---\n"
        content += "created: \(dateFormatter.string(from: createdAt))\n"
        content += "description: \"\(String(text.prefix(50)))\"\n"
        if !tags.isEmpty {
            content += "tags:\n"
            for tag in tags {
                content += "  - \"\(tag)\"\n"
            }
        }
        content += "---\n\n"
        content += text
        return content
    }

    private static func fileName(for date: Date) -> String {
        dateFormatter.string(from: date) + ".md"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm-ss"
        return formatter
    }()
}
