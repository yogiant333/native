// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:ffigen/src/code_generator.dart';
import 'package:ffigen/src/code_generator/utils.dart';
import 'package:logging/logging.dart';

import '../strings.dart' as strings;

final _logger = Logger('ffigen.code_generator.writer');

/// To store generated String bindings.
class Writer {
  final String? header;

  /// Holds bindings, which lookup symbols.
  final List<Binding> lookUpBindings;

  /// Holds bindings, which lookup symbols through `FfiNative`.
  final List<Binding> ffiNativeBindings;

  /// Holds bindings which don't lookup symbols.
  final List<Binding> noLookUpBindings;

  /// The default asset id to use for [ffiNativeBindings].
  final String? nativeAssetId;

  /// Manages the `_SymbolAddress` class.
  final symbolAddressWriter = SymbolAddressWriter();

  late String _className;
  String get className => _className;

  final String? classDocComment;

  String? _ffiLibraryPrefix;
  String get ffiLibraryPrefix {
    if (_ffiLibraryPrefix != null) {
      return _ffiLibraryPrefix!;
    }

    final import = _usedImports.firstWhere(
        (element) => element.name == ffiImport.name,
        orElse: () => ffiImport);
    _usedImports.add(import);
    return _ffiLibraryPrefix = import.prefix;
  }

  String? _ffiPkgLibraryPrefix;
  String get ffiPkgLibraryPrefix {
    if (_ffiPkgLibraryPrefix != null) {
      return _ffiPkgLibraryPrefix!;
    }

    final import = _usedImports.firstWhere(
        (element) => element.name == ffiPkgImport.name,
        orElse: () => ffiPkgImport);
    _usedImports.add(import);
    return _ffiPkgLibraryPrefix = import.prefix;
  }

  late String selfImportPrefix = () {
    final import = _usedImports
        .firstWhere((element) => element.name == self.name, orElse: () => self);
    _usedImports.add(import);
    return import.prefix;
  }();

  final Set<LibraryImport> _usedImports = {};

  late String _lookupFuncIdentifier;
  String get lookupFuncIdentifier => _lookupFuncIdentifier;

  late String _symbolAddressClassName;
  late String _symbolAddressVariableName;
  late String _symbolAddressLibraryVarName;

  /// Initial namers set after running constructor. Namers are reset to this
  /// initial state everytime [generate] is called.
  late UniqueNamer _initialTopLevelUniqueNamer, _initialWrapperLevelUniqueNamer;

  /// Used by [Binding]s for generating required code.
  late UniqueNamer _topLevelUniqueNamer, _wrapperLevelUniqueNamer;
  UniqueNamer get topLevelUniqueNamer => _topLevelUniqueNamer;
  UniqueNamer get wrapperLevelUniqueNamer => _wrapperLevelUniqueNamer;

  late String _arrayHelperClassPrefix;

  /// Guaranteed to be a unique prefix.
  String get arrayHelperClassPrefix => _arrayHelperClassPrefix;

  /// Set true after calling [generate]. Indicates if
  /// [generateSymbolOutputYamlMap] can be called.
  bool get canGenerateSymbolOutput => _canGenerateSymbolOutput;
  bool _canGenerateSymbolOutput = false;

  /// [_usedUpNames] should contain names of all the declarations which are
  /// already used. This is used to avoid name collisions.
  Writer({
    required this.lookUpBindings,
    required this.ffiNativeBindings,
    required this.noLookUpBindings,
    required String className,
    required this.nativeAssetId,
    Set<LibraryImport>? additionalImports,
    this.classDocComment,
    this.header,
  }) {
    final globalLevelNameSet = noLookUpBindings.map((e) => e.name).toSet();
    final wrapperLevelNameSet = lookUpBindings.map((e) => e.name).toSet();
    final allNameSet = <String>{}
      ..addAll(globalLevelNameSet)
      ..addAll(wrapperLevelNameSet);

    _initialTopLevelUniqueNamer = UniqueNamer(globalLevelNameSet);
    _initialWrapperLevelUniqueNamer = UniqueNamer(wrapperLevelNameSet);
    final allLevelsUniqueNamer = UniqueNamer(allNameSet);

    /// Wrapper class name must be unique among all names.
    _className = _resolveNameConflict(
      name: className,
      makeUnique: allLevelsUniqueNamer,
      markUsed: [_initialWrapperLevelUniqueNamer, _initialTopLevelUniqueNamer],
    );

    /// Library imports prefix should be unique unique among all names.
    if (additionalImports != null) {
      for (final lib in additionalImports) {
        lib.prefix = _resolveNameConflict(
          name: lib.prefix,
          makeUnique: allLevelsUniqueNamer,
          markUsed: [
            _initialWrapperLevelUniqueNamer,
            _initialTopLevelUniqueNamer
          ],
        );
      }
    }

    /// [_lookupFuncIdentifier] should be unique in top level.
    _lookupFuncIdentifier = _resolveNameConflict(
      name: '_lookup',
      makeUnique: _initialTopLevelUniqueNamer,
      markUsed: [_initialTopLevelUniqueNamer],
    );

    /// Resolve name conflicts of identifiers used for SymbolAddresses.
    _symbolAddressClassName = _resolveNameConflict(
      name: '_SymbolAddresses',
      makeUnique: allLevelsUniqueNamer,
      markUsed: [_initialWrapperLevelUniqueNamer, _initialTopLevelUniqueNamer],
    );
    _symbolAddressVariableName = _resolveNameConflict(
      name: 'addresses',
      makeUnique: _initialWrapperLevelUniqueNamer,
      markUsed: [_initialWrapperLevelUniqueNamer],
    );
    _symbolAddressLibraryVarName = _resolveNameConflict(
      name: '_library',
      makeUnique: _initialWrapperLevelUniqueNamer,
      markUsed: [_initialWrapperLevelUniqueNamer],
    );

    /// Finding a unique prefix for Array Helper Classes and store into
    /// [_arrayHelperClassPrefix].
    final base = 'ArrayHelper';
    _arrayHelperClassPrefix = base;
    var suffixInt = 0;
    for (var i = 0; i < allNameSet.length; i++) {
      if (allNameSet.elementAt(i).startsWith(_arrayHelperClassPrefix)) {
        // Not a unique prefix, start over with a new suffix.
        i = -1;
        suffixInt++;
        _arrayHelperClassPrefix = '$base$suffixInt';
      }
    }

    _resetUniqueNamersNamers();
  }

  /// Resolved name conflict using [makeUnique] and marks the result as used in
  /// all [markUsed].
  String _resolveNameConflict({
    required String name,
    required UniqueNamer makeUnique,
    List<UniqueNamer> markUsed = const [],
  }) {
    final s = makeUnique.makeUnique(name);
    for (final un in markUsed) {
      un.markUsed(s);
    }
    return s;
  }

  /// Resets the namers to initial state. Namers are reset before generating.
  void _resetUniqueNamersNamers() {
    _topLevelUniqueNamer = _initialTopLevelUniqueNamer.clone();
    _wrapperLevelUniqueNamer = _initialWrapperLevelUniqueNamer.clone();
  }

  void markImportUsed(LibraryImport import) {
    _usedImports.add(import);
  }

  /// Writes all bindings to a String.
  String generate() {
    final s = StringBuffer();

    // We write the source first to determine which imports are actually
    // referenced. Headers and [s] are then combined into the final result.
    final result = StringBuffer();

    // Reset unique namers to initial state.
    _resetUniqueNamersNamers();

    // Write file header (if any).
    if (header != null) {
      result.writeln(header);
    }

    // Write auto generated declaration.
    result.write(makeDoc(
        'AUTO GENERATED FILE, DO NOT EDIT.\n\nGenerated by `package:ffigen`.'));

    // Write lint ignore if not specified by user already.
    if (!RegExp(r'ignore_for_file:\s*type\s*=\s*lint').hasMatch(header ?? '')) {
      result.write(makeDoc('ignore_for_file: type=lint'));
    }

    // If there are any @Native bindings, the file needs to have an
    // `@DefaultAsset` annotation for the symbols to resolve properly. This
    // avoids duplicating the asset on every element.
    // Since the annotation goes on a `library;` directive, it needs to appear
    // before other definitions in the file.
    if (ffiNativeBindings.isNotEmpty && nativeAssetId != null) {
      result
        ..writeln("@$ffiLibraryPrefix.DefaultAsset('$nativeAssetId')")
        ..writeln('library;\n');
    }

    /// Write [lookUpBindings].
    if (lookUpBindings.isNotEmpty) {
      // Write doc comment for wrapper class.
      if (classDocComment != null) {
        s.write(makeDartDoc(classDocComment!));
      }
      // Write wrapper classs.
      s.write('class $_className{\n');
      // Write dylib.
      s.write('/// Holds the symbol lookup function.\n');
      s.write(
          'final $ffiLibraryPrefix.Pointer<T> Function<T extends $ffiLibraryPrefix.NativeType>(String symbolName) $lookupFuncIdentifier;\n');
      s.write('\n');
      //Write doc comment for wrapper class constructor.
      s.write(makeDartDoc('The symbols are looked up in [dynamicLibrary].'));
      // Write wrapper class constructor.
      s.write(
          '$_className($ffiLibraryPrefix.DynamicLibrary dynamicLibrary): $lookupFuncIdentifier = dynamicLibrary.lookup;\n\n');
      //Write doc comment for wrapper class named constructor.
      s.write(makeDartDoc('The symbols are looked up with [lookup].'));
      // Write wrapper class named constructor.
      s.write(
          '$_className.fromLookup($ffiLibraryPrefix.Pointer<T> Function<T extends $ffiLibraryPrefix.NativeType>(String symbolName) lookup): $lookupFuncIdentifier = lookup;\n\n');
      for (final b in lookUpBindings) {
        s.write(b.toBindingString(this).string);
      }
      if (symbolAddressWriter.shouldGenerate) {
        s.write(symbolAddressWriter.writeObject(this));
      }

      s.write('}\n\n');
    }

    if (ffiNativeBindings.isNotEmpty) {
      for (final b in ffiNativeBindings) {
        s.write(b.toBindingString(this).string);
      }

      if (symbolAddressWriter.shouldGenerate) {
        s.write(symbolAddressWriter.writeObject(this));
      }
    }

    if (symbolAddressWriter.shouldGenerate) {
      s.write(symbolAddressWriter.writeClass(this));
    }

    /// Write [noLookUpBindings].
    for (final b in noLookUpBindings) {
      s.write(b.toBindingString(this).string);
    }

    // Write neccesary imports.
    for (final lib in _usedImports) {
      result
        ..write("import '${lib.importPath}' as ${lib.prefix};")
        ..write('\n');
    }
    result.write(s);

    _canGenerateSymbolOutput = true;
    return result.toString();
  }

  Map<String, dynamic> generateSymbolOutputYamlMap(String importFilePath) {
    final bindings = <Binding>[
      ...noLookUpBindings,
      ...ffiNativeBindings,
      ...lookUpBindings
    ];
    if (!canGenerateSymbolOutput) {
      throw Exception(
          "Invalid state: generateSymbolOutputYamlMap() called before generate()");
    }
    final result = <String, dynamic>{};

    result[strings.formatVersion] = strings.symbolFileFormatVersion;
    result[strings.files] = <String, dynamic>{};
    result[strings.files][importFilePath] = <String, dynamic>{};

    final fileConfig = result[strings.files][importFilePath];
    fileConfig[strings.usedConfig] = <String, dynamic>{};

    // Warn for macros.
    final hasMacroBindings = bindings.any(
        (element) => element is Constant && element.usr.contains('@macro@'));
    if (hasMacroBindings) {
      _logger.info(
          'Removing all Macros from symbol file since they cannot be cross referenced reliably.');
    }
    // Remove internal bindings and macros.
    bindings.removeWhere((element) {
      return element.isInternal ||
          (element is Constant && element.usr.contains('@macro@'));
    });
    // Sort bindings alphabetically by USR.
    bindings.sort((a, b) => a.usr.compareTo(b.usr));
    fileConfig[strings.usedConfig][strings.ffiNative] = bindings
        .whereType<Func>()
        .any((element) => element.ffiNativeConfig.enabled);
    fileConfig[strings.symbols] = <String, dynamic>{};
    final symbolConfig = fileConfig[strings.symbols];
    for (final binding in bindings) {
      symbolConfig[binding.usr] = {
        strings.name: binding.name,
      };
    }
    return result;
  }
}

/// Manages the generated `_SymbolAddress` class.
class SymbolAddressWriter {
  final List<_SymbolAddressUnit> _addresses = [];

  /// Used to check if we need to generate `_SymbolAddress` class.
  bool get shouldGenerate => _addresses.isNotEmpty;

  bool get hasNonNativeAddress => _addresses.any((e) => !e.native);

  void addSymbol({
    required String type,
    required String name,
    required String ptrName,
  }) {
    _addresses.add(_SymbolAddressUnit(type, name, ptrName, false));
  }

  void addNativeSymbol({required String type, required String name}) {
    _addresses.add(_SymbolAddressUnit(type, name, '', true));
  }

  String writeObject(Writer w) {
    final className = w._symbolAddressClassName;
    final fieldName = w._symbolAddressVariableName;

    if (hasNonNativeAddress) {
      return 'late final $fieldName = $className(this);';
    } else {
      return 'const $fieldName = $className();';
    }
  }

  String writeClass(Writer w) {
    final sb = StringBuffer();
    sb.write('class ${w._symbolAddressClassName} {\n');

    if (hasNonNativeAddress) {
      // Write Library object.
      sb.write('final ${w._className} ${w._symbolAddressLibraryVarName};\n');
      // Write Constructor.
      sb.write(
          '${w._symbolAddressClassName}(this.${w._symbolAddressLibraryVarName});\n');
    } else {
      // Native bindings are top-level, so we don't need a field here.
      sb.write('const ${w._symbolAddressClassName}();');
    }

    for (final address in _addresses) {
      sb.write('${address.type} get ${address.name} => ');

      if (address.native) {
        // For native fields and functions, we can use Native.addressOf to look
        // up their address.
        // The name of address getter shadows the actual element in the library,
        // so we need to use a self-import.
        final arg = '${w.selfImportPrefix}.${address.name}';
        sb.writeln('${w.ffiLibraryPrefix}.Native.addressOf($arg);');
      } else {
        // For other elements, the generator will write a private field of type
        // Pointer which we can reference here.
        sb.writeln('${w._symbolAddressLibraryVarName}.${address.ptrName};');
      }
    }
    sb.write('}\n');
    return sb.toString();
  }
}

/// Holds the data for a single symbol address.
class _SymbolAddressUnit {
  final String type, name, ptrName;

  /// Whether the symbol we're looking up has been declared with `@Native`.
  final bool native;

  _SymbolAddressUnit(this.type, this.name, this.ptrName, this.native);
}
