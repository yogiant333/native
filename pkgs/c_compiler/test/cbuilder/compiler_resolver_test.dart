// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:c_compiler/c_compiler.dart';
import 'package:c_compiler/src/cbuilder/compiler_resolver.dart';
import 'package:c_compiler/src/tool/tool_error.dart';
import 'package:native_assets_cli/native_assets_cli.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  test('Config provided compiler', () async {
    await inTempDir((tempUri) async {
      final ar = [
        ...await appleAr.defaultResolver!.resolve(logger: logger),
        ...await llvmAr.defaultResolver!.resolve(logger: logger),
      ].first.uri;
      final cc = [
        ...await appleClang.defaultResolver!.resolve(logger: logger),
        ...await clang.defaultResolver!.resolve(logger: logger),
      ].first.uri;
      final ld = [
        ...await appleLd.defaultResolver!.resolve(logger: logger),
        ...await lld.defaultResolver!.resolve(logger: logger),
      ].first.uri;
      final buildConfig = BuildConfig(
        outDir: tempUri,
        packageRoot: tempUri,
        target: Target.current,
        packaging: PackagingPreference.dynamic,
        ar: ar,
        cc: cc,
        ld: ld,
      );
      final resolver =
          CompilerResolver(buildConfig: buildConfig, logger: logger);
      final compiler = await resolver.resolveCompiler();
      final archiver = await resolver.resolveArchiver();
      expect(compiler.uri, buildConfig.cc);
      expect(archiver.uri, buildConfig.ar);
    });
  });

  test('No compiler found', () async {
    await inTempDir((tempUri) async {
      final buildConfig = BuildConfig(
        outDir: tempUri,
        packageRoot: tempUri,
        target: Target.windowsX64,
        packaging: PackagingPreference.dynamic,
      );
      final resolver = CompilerResolver(
        buildConfig: buildConfig,
        logger: logger,
        host: Target.androidArm64, // This is never a host.
      );
      expect(resolver.resolveCompiler, throwsA(isA<ToolError>()));
      expect(resolver.resolveArchiver, throwsA(isA<ToolError>()));
    });
  });
}