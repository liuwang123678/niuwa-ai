/// N1 内核的唯一出口。
///
/// **这个目录下不许 import `package:flutter/`**——内核要能脱离界面单独测试，
/// 将来也能单独抽成命令行工具。`test/core_is_pure_test.dart` 守着这条线。
///
/// 界面层只从这个文件导入，不要深入到各个子文件里去——那样内核重构时会牵一大片。
library;

export 'agent/agent_event.dart';
export 'agent/agent_loop.dart';
export 'agent/prompt_builder.dart';
export 'agent/conversation_digest.dart';
export 'agent/work_level.dart';
export 'browser/browser_driver.dart';
export 'browser/snapshot_script.dart';
export 'code/audit_log.dart';
export 'code/code_runner.dart';
export 'code/danger_command.dart';
export 'code/file_backup.dart';
export 'code/file_policy.dart';
export 'code/js_script.dart';
export 'code/path_resolver.dart';
export 'image/image_prep.dart';
export 'image/image_window.dart';
export 'llm/llm_client.dart';
export 'llm/openai_compat_client.dart';
export 'llm/providers.dart';
export 'memory/memory_store.dart';
export 'memory/memory_summarizer.dart';
export 'models/attachment.dart';
export 'models/chat_message.dart';
export 'reminder/reminder.dart';
export 'reminder/reminder_scheduler.dart';
export 'reminder/reminder_store.dart';
export 'skills/skill.dart';
export 'skills/skill_registry.dart';
export 'todo/todo_list.dart';
export 'tools/builtin/basic_tools.dart';
export 'tools/builtin/browser_tools.dart';
export 'tools/builtin/code_tools.dart';
export 'tools/builtin/doc_tools.dart';
export 'tools/builtin/file_tools.dart';
export 'mcp/mcp_client.dart';
export 'mcp/mcp_config.dart';
export 'tools/builtin/mcp_tools.dart';
export 'tools/builtin/memory_tools.dart';
export 'tools/builtin/reminder_tools.dart';
export 'tools/builtin/skill_tools.dart';
export 'tools/builtin/subagent_tool.dart';
export 'tools/builtin/todo_tools.dart';
export 'tools/n1_tool.dart';
export 'tools/tool_approval.dart';
export 'tools/auto_approval.dart';
export 'tools/tool_context.dart';
export 'tools/tool_registry.dart';
export 'util/clip.dart';
export 'util/ids.dart';
