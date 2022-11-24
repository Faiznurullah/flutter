// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dds/dap.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/convert.dart';
import 'package:flutter_tools/src/debug_adapters/flutter_adapter.dart';
import 'package:flutter_tools/src/debug_adapters/flutter_test_adapter.dart';

/// A [FlutterDebugAdapter] that captures what process/args will be launched.
class MockFlutterDebugAdapter extends FlutterDebugAdapter {
  factory MockFlutterDebugAdapter({
    required FileSystem fileSystem,
    required Platform platform,
    bool simulateAppStarted = true,
  }) {
    final StreamController<List<int>> stdinController = StreamController<List<int>>();
    final StreamController<List<int>> stdoutController = StreamController<List<int>>();
    final ByteStreamServerChannel channel = ByteStreamServerChannel(stdinController.stream, stdoutController.sink, null);
    final ByteStreamServerChannel clientChannel = ByteStreamServerChannel(stdoutController.stream, stdinController.sink, null);

    return MockFlutterDebugAdapter._(
      channel,
      clientChannel: clientChannel,
      fileSystem: fileSystem,
      platform: platform,
      simulateAppStarted: simulateAppStarted,
    );
  }

  MockFlutterDebugAdapter._(
    super.channel, {
    required this.clientChannel,
    required super.fileSystem,
    required super.platform,
    this.simulateAppStarted = true,
  }) {
    clientChannel.listen((ProtocolMessage message) {
      _handleDapToClientMessage(message);
    });
  }

  int _seq = 1;
  final ByteStreamServerChannel clientChannel;
  final bool simulateAppStarted;

  late String executable;
  late List<String> processArgs;
  late Map<String, String>? env;

  /// A list of all messages sent to the `flutter run` processes `stdin`.
  final List<Map<String, Object?>> flutterMessages = <Map<String, Object?>>[];

  /// The `method`s of all requests send to the `flutter run` processes `stdin`.
  List<String> get flutterRequests => flutterMessages
      .map((Map<String, Object?> message) => message['method'] as String?)
      .whereNotNull()
      .toList();

  /// A handler for the 'app.exposeUrl' reverse-request.
  String Function(String)? exposeUrlHandler;

  @override
  Future<void> launchAsProcess({
    required String executable,
    required List<String> processArgs,
    required Map<String, String>? env,
  }) async {
    this.executable = executable;
    this.processArgs = processArgs;
    this.env = env;

    // Simulate the app starting by triggering handling of events that Flutter
    // would usually write to stdout.
    if (simulateAppStarted) {
      simulateStdoutMessage(<String, Object?>{
        'event': 'app.started',
      });
      simulateStdoutMessage(<String, Object?>{
        'event': 'app.start',
        'params': <String, Object?>{
          'appId': 'TEST',
        }
      });
    }
  }

  /// Handles messages sent from the debug adapter back to the client.
  void _handleDapToClientMessage(ProtocolMessage message) {
    // Pretend to be the client, delegating any reverse-requests to the relevant
    // handler that is provided by the test.
    if (message is Event && message.event == 'flutter.forwardedRequest') {
      final Map<String, Object?> body = (message.body as Map<String, Object?>?)!;
      final String method = (body['method'] as String?)!;
      final Map<String, Object?>? params = body['params'] as Map<String, Object?>?;

      final Object? result = _handleReverseRequest(method, params);

      // Send the result back in the same way the client would.
      clientChannel.sendRequest(Request(
        seq: _seq++,
        command: 'flutter.sendForwardedRequestResponse',
        arguments: <String, Object?>{
          'id': body['id'],
          'result': result,
        },
      ));
    }
  }

  Object? _handleReverseRequest(String method, Map<String, Object?>? params) {
    switch (method) {
      case 'app.exposeUrl':
        final String url = (params!['url'] as String?)!;
        return exposeUrlHandler!(url);
      default:
        throw ArgumentError('Reverse-request $method is unknown');
    }
  }

  /// Simulates a message emitted by the `flutter run` process by directly
  /// calling the debug adapters [handleStdout] method.
  void simulateStdoutMessage(Map<String, Object?> message) {
    // Messages are wrapped in a list because Flutter only processes messages
    // wrapped in brackets.
    handleStdout(jsonEncode(<Object?>[message]));
  }

  @override
  void sendFlutterMessage(Map<String, Object?> message) {
    flutterMessages.add(message);
    // Don't call super because it will try to write to the process that we
    // didn't actually spawn.
  }

  @override
  Future<void> get debuggerInitialized {
    // If we were mocking debug mode, then simulate the debugger initializing.
    return enableDebugger
        ? Future<void>.value()
        : throw StateError('Invalid attempt to wait for debuggerInitialized when not debugging');
  }
}

/// A [FlutterTestDebugAdapter] that captures what process/args will be launched.
class MockFlutterTestDebugAdapter extends FlutterTestDebugAdapter {
  factory MockFlutterTestDebugAdapter({
    required FileSystem fileSystem,
    required Platform platform,
  }) {
    final StreamController<List<int>> stdinController = StreamController<List<int>>();
    final StreamController<List<int>> stdoutController = StreamController<List<int>>();
    final ByteStreamServerChannel channel = ByteStreamServerChannel(stdinController.stream, stdoutController.sink, null);

    return MockFlutterTestDebugAdapter._(
      stdinController.sink,
      stdoutController.stream,
      channel,
      fileSystem: fileSystem,
      platform: platform,
    );
  }

  MockFlutterTestDebugAdapter._(
    this.stdin,
    this.stdout,
    ByteStreamServerChannel channel, {
    required FileSystem fileSystem,
    required Platform platform,
  }) : super(channel, fileSystem: fileSystem, platform: platform);

  final StreamSink<List<int>> stdin;
  final Stream<List<int>> stdout;

  late String executable;
  late List<String> processArgs;
  late Map<String, String>? env;

  @override
  Future<void> launchAsProcess({
    required String executable,
    required List<String> processArgs,
    required Map<String, String>? env,
  }) async {
    this.executable = executable;
    this.processArgs = processArgs;
    this.env = env;
  }

  @override
  Future<void> get debuggerInitialized {
    // If we were mocking debug mode, then simulate the debugger initializing.
    return enableDebugger
        ? Future<void>.value()
        : throw StateError('Invalid attempt to wait for debuggerInitialized when not debugging');
  }
}

class MockRequest extends Request {
  MockRequest()
      : super.fromMap(<String, Object?>{
          'command': 'mock_command',
          'type': 'mock_type',
          'seq': _requestId++,
        });

  static int _requestId = 1;
}
