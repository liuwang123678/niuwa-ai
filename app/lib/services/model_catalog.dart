import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/llm/providers.dart';

/// 拉「这个平台现在有哪些模型」。
///
/// ## 为什么需要它
///
/// 预置表里的模型名**一定会烂**。各家一年退役一两个是常态，而退役之后接口回的是
/// 404「模型不存在」——那个症状看着特别像网络故障或者 Key 不对，用户会往错的方向
/// 查很久（Kimi 那条 `kimi-k2.5` 就是这么坑了一次）。
///
/// 与其一年手工校一次表，不如让用户当场拉一份出来挑。地址怎么拼见 [modelsUrl]。
///
/// ## 一句话说到位的边界：这是**建议**，不是白名单
///
/// - 拉到的列表**只用来挑**，挑完还落在原来那个可编辑的输入框里
/// - 拉不到、或者拉到了但不是你想用的那个，照样能手填
/// - **不做成"只有列表里有的才能用"**：那等于把一份我们没验证过的名单当成真理
///   （各家筛不筛、排不排序都不一样），比让人手填更糟
///
/// ## 实测
///
/// 2026-10-10：本机能连上的五家，不带 Key 请求 `{base}/models` 一律回 401 而不是
/// 404——路都在。真带 Key 拉回来的形状各家有出入，所以 [_extractIds] 同时认
/// `data[].id`（OpenAI 那一套）和 `models[].name`（有些自建网关这么回）。
class ModelCatalog {
  /// [clientFactory] 每次拉列表开一个，拉完就关——省得一个卡住的连接挂着不放。
  /// 测试注入一个假的就行。
  ModelCatalog({
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 20),
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;

  /// 拉一次最多等多久。默认 20 秒——比聊天那 60 秒短，因为这里只是**列表**，
  /// 等太久用户还不如直接手填。
  final Duration timeout;

  /// 去拉。失败一律翻成 [ModelCatalogException]，里面那句话是给用户看的。
  ///
  /// 成功时返回**去重后的 id 表，保持平台给的顺序**（各家常把新的、主推的放前面，
  /// 按字母重排会把这份策展打乱）。
  Future<List<String>> fetch({
    required String baseUrl,
    required String apiKey,
  }) async {
    final url = modelsUrl(baseUrl);
    // 地址没填就别走到 http 层去——那里报出来的会是"无效的 URL"之类，
    // 看不出是"设置里少填了一栏"。
    if (url.isEmpty) {
      throw const ModelCatalogException('还没填接口地址。先去上面把地址填上。');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ModelCatalogException('这个地址看着不像个网址：$baseUrl');
    }

    final client = _clientFactory();
    try {
      final http.Response response;
      try {
        response = await client
            .get(
              uri,
              headers: {
                'Accept': 'application/json',
                // 本机 Ollama 不需要 Key。空串干脆不发这个头，免得某些网关
                // 把空 Authorization 直接当鉴权失败。
                if (apiKey.trim().isNotEmpty)
                  'Authorization': 'Bearer ${apiKey.trim()}',
              },
            )
            .timeout(timeout);
      } on TimeoutException {
        throw ModelCatalogException(
          '等了 ${timeout.inSeconds} 秒没反应——网络不通，或者地址填错了。',
        );
      } catch (e) {
        // 真后端在这儿抛的是 SocketException / ClientException，
        // 两种都只会给一句英文，用户看不懂，包一层。
        throw ModelCatalogException('连不上：$e');
      }

      final body = response.body;
      if (response.statusCode != 200) {
        throw ModelCatalogException(
          _humanizeStatus(response.statusCode, body),
          statusCode: response.statusCode,
        );
      }

      final ids = _extractIds(body);
      if (ids.isEmpty) {
        throw const ModelCatalogException(
          '拉回来了，但里面一个模型名都没有——这个平台的列表可能得带上权限才看得见。'
          '手填模型名吧。',
        );
      }
      return ids;
    } finally {
      client.close();
    }
  }

  /// 从回包里抠出模型名。
  ///
  /// 认三种形状，因为"兼容 OpenAI"的网关实现起来尺度不一样：
  ///
  ///     {"data":  [{"id": "kimi-k3"}, ...]}          OpenAI 官方那套
  ///     {"models":[{"name": "qwen3:8b"}, ...]}       有些网关、以及 Ollama 的旧接口
  ///     {"data":  ["kimi-k3", ...]}                  简化到只剩字符串的
  static List<String> _extractIds(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      // 地址填成网站首页了（那边回的是 HTML），这种一定要说破，
      // 否则用户会以为"这家平台不支持拉列表"。
      throw const ModelCatalogException(
        '这个地址回的不是 JSON，多半是填成网站首页了。'
        '要的是接口地址，一般以 /v1 结尾。',
      );
    }

    final raw = switch (decoded) {
      Map<String, Object?>() => _firstList(decoded),
      // 有些网关直接把数组当顶层。
      List<Object?>() => decoded,
      _ => null,
    };
    if (raw == null) return const [];

    final seen = <String>{};
    final ids = <String>[];
    for (final item in raw) {
      final id = switch (item) {
        String() => item,
        Map<String, Object?>() =>
          _firstString(item, const ['id', 'name', 'model']),
        _ => null,
      };
      final clean = id?.trim();
      if (clean == null || clean.isEmpty) continue;
      if (!seen.add(clean)) continue;
      ids.add(clean);
    }
    return ids;
  }

  static List<Object?>? _firstList(Map<String, Object?> map) {
    for (final key in const ['data', 'models', 'data_models']) {
      final v = map[key];
      if (v is List) return v;
    }
    return null;
  }

  static String? _firstString(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      final v = map[key];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  /// HTTP 状态码翻成人话。跟 `openai_compat_client.dart` 的 `_humanizeError`
  /// 是一回事，但那边的话是"发消息失败了"，这边是"拉列表失败了"，
  /// 该指的动作不一样，所以不共用。
  static String _humanizeStatus(int status, String body) {
    final detail = _errorDetail(body);
    final suffix = detail == null ? '' : '：$detail';

    return switch (status) {
      401 || 403 =>
        '这个平台不认这个 Key（HTTP $status）$suffix。'
            '先去上面把 Key 填对——有些平台的 Key 只在申请时显示一次。',
      404 =>
        '这个平台没有「列出模型」这条接口（HTTP 404）$suffix。'
            '去它官网的文档里查当前的名字，手填就行。',
      429 => '问得太勤了，等一下再拉$suffix',
      >= 500 => '平台服务端出错了（$status），过会儿再试$suffix',
      _ => '拉不到（HTTP $status）$suffix',
    };
  }

  static String? _errorDetail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) return null;
      final error = decoded['error'];
      if (error is String && error.trim().isNotEmpty) return error.trim();
      if (error is Map<String, Object?>) {
        final message = error['message'];
        if (message is String && message.trim().isNotEmpty) return message.trim();
      }
      final message = decoded['message'];
      if (message is String && message.trim().isNotEmpty) return message.trim();
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// 拉列表失败。[message] 是给用户看的中文，界面直接显示它。
class ModelCatalogException implements Exception {
  const ModelCatalogException(this.message, {this.statusCode});

  final String message;

  /// HTTP 状态码，网络层面的失败是 null。想知道是"Key 不对"还是"路不通"
  /// 的时候用得上。
  final int? statusCode;

  @override
  String toString() => message;
}
