// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library services.completion.dart.sorter.common;

import 'dart:async';
import 'dart:io' as io;
import 'dart:convert' as convert;

import 'package:analysis_server/src/protocol_server.dart' as protocol;
import 'package:analysis_server/src/protocol_server.dart'
    show CompletionSuggestion, CompletionSuggestionKind;
import 'package:analysis_server/src/provisional/completion/completion_core.dart';
import 'package:analysis_server/src/provisional/completion/dart/completion_dart.dart';
import 'package:analysis_server/src/provisional/completion/dart/completion_target.dart';
import 'package:analysis_server/src/services/completion/dart/contribution_sorter.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/task/dart.dart';
import 'package:analyzer/task/dart.dart';

import 'package:smart/completion_model/model.dart' as smart_model;
import 'package:smart/completion_model/ast_extractors.dart' as smart_model_extractor;

import 'package:smart/completion_server/log_client.dart' as log;

// import 'package:logging/logging.dart' as log;

part 'common_usage_sorter.g.dart';

smart_model.Model model;

// log.Logger _log = new log.Logger("common_usage_sorter");

class _log {
  static Future info(String l) {
    return log.info("common_usage_sorter", l);
  }
}

/**
 * A computer for adjusting the relevance of completions computed by others
 * based upon common Dart usage patterns. This is a long-lived object
 * that should not maintain state between calls to it's [sort] method.
 */
class CommonUsageSorter implements DartContributionSorter {


  /**
   * A map of <library>.<classname> to an ordered list of method names,
   * field names, getter names, and named constructors.
   * The names are ordered from most relevant to least relevant.
   * Names not listed are considered equally less relevant than those listed.
   */
  Map<String, List<String>> selectorRelevance;

  CommonUsageSorter([this.selectorRelevance = defaultSelectorRelevance]);

  @override
  Future sort(DartCompletionRequest request,
      Iterable<CompletionSuggestion> suggestions) async {
    await _update(request, suggestions);
    return new Future.value();
  }

  CompletionTarget _getCompletionTarget(CompletionRequest request) {
    // TODO (danrubel) get cached completion target
    var libSrcs = request.context.getLibrariesContaining(request.source);
    if (libSrcs.length == 0) {
      return null;
    }
    var libElem = request.context.getResult(libSrcs[0], LIBRARY_ELEMENT1);
    if (libElem is LibraryElement) {
      var unit = request.context.getResult(
          new LibrarySpecificUnit(libElem.source, request.source),
          RESOLVED_UNIT3);
      if (unit is CompilationUnit) {
        return new CompletionTarget.forOffset(unit, request.offset);
      }
    }
    return null;
  }

  /**
   * Adjusts the relevance based on the given completion context.
   * The compilation unit and completion node
   * in the given completion context may not be resolved.
   */
  Future _update(
      CompletionRequest request, Iterable<CompletionSuggestion> suggestions) async {
        var target = _getCompletionTarget(request);
        _log.info("completionTarget: $target");

        _log.info("About to _update: $request");
        _log.info("Model $model");

        var completionScores;
        var features;


        try {


          if (model == null) {
            _log.info("Initting model");

            String homeDir = io.Platform.environment["HOME"];
            String workingPath = homeDir + "/" + "feature_files";

            model = new smart_model.Model(workingPath);
            _log.info("Model init complete");

          }

          _log.info("Request Target: $request");
          _log.info("target.containingNode: ${target.containingNode}");
          _log.info("target.entity: ${target.entity}");
          _log.info("targetRuntimeType: ${target.containingNode.runtimeType}");

          Stopwatch sw = new Stopwatch()..start();

          if (target.containingNode is MethodInvocation) {
            _log.info("Method invocation");
            var node = target.containingNode as MethodInvocation;
            features = smart_model_extractor.featuresFromMethodInvocation(node);
          } else if (target.containingNode is PropertyAccess) {
            _log.info("Method property access");
            var node = target.containingNode as PropertyAccess;
            features = smart_model_extractor.featuresFromPropertyAccess(node);
          } else if (target.containingNode is PrefixedIdentifier) {
            _log.info("Method prefixed identifier");
            var node = target.containingNode as PrefixedIdentifier;
            features = smart_model_extractor.featuresFromPrefixedIdentifier(node);
          } else {
            // Completion on unworkable note
            _log.info("Target node type not supported");
            return new Future.value();
          }

          _log.info("Features for Node computed: ${sw.elapsedMilliseconds}");
          _log.info(convert.JSON.encode(features));

          completionScores = model.scoreCompletionOrder(features);

          // log("Completion scores");
          // log(convert.JSON.encode(completionScores));

          _log.info ("Extraction complete: ${sw.elapsedMilliseconds}/ms");

        } catch (e, st) {
          await _log.info ("Crash: $e \n $st");
        }
        //
        // log("Adaptive ordering completed");
        // log("Completion scores: $completionScores");
        //


        var completionList = completionScores.keys.toList()..sort((k1, k2) =>
          completionScores[k1]["Overall_PValue"].compareTo(
            completionScores[k2]["Overall_PValue"]
          ));

          _log.info ("TargetType: ${features["TargetType"]}");

          completionList = completionList.reversed.toList();

          _log.info ("Ordered completion List:\n"
            "${convert.JSON.encode(completionList)}");

          _log.info ("Suggestions List:\n"
            "${convert.JSON.encode(suggestions.map((s) => s.completion).toList())}");

    if (target != null) {
      var visitor = new _BestTypeVisitor(target.entity);
      DartType type = target.containingNode.accept(visitor);
      if (type != null) {
        Element typeElem = type.element;
        if (typeElem != null) {
          LibraryElement libElem = typeElem.library;
          if (libElem != null) {
            _updateInvocationRelevance(type, libElem, suggestions, completionList);
          }
        }
      }
    }
  }


  /**
   * Adjusts the relevance of all method suggestions based upon the given
   * target type and library.
   */
  void _updateInvocationRelevance(DartType type, LibraryElement libElem,
      Iterable<CompletionSuggestion> suggestions, List<String> order) {
    String typeName = type.name;
      for (CompletionSuggestion suggestion in suggestions) {
        String suggestionSummary = convert.JSON.encode({
          "kind" : suggestion.kind,
          "completion" : suggestion.completion,
        });
        _log.info("Suggestion being ordered: ${suggestionSummary}");

        protocol.Element element = suggestion.element;

        if (element != null &&
            (element.kind == protocol.ElementKind.CONSTRUCTOR ||
                element.kind == protocol.ElementKind.FIELD ||
                element.kind == protocol.ElementKind.GETTER ||
                element.kind == protocol.ElementKind.METHOD ||
                element.kind == protocol.ElementKind.SETTER) &&
            suggestion.kind == CompletionSuggestionKind.INVOCATION &&
            suggestion.declaringType == typeName) {
          int index = order.indexOf(suggestion.completion);
          if (index != -1) {
            int newRelevance = DART_RELEVANCE_COMMON_USAGE - index;
            _log.info("Updating relevance: ${suggestion.completion}: ${suggestion.relevance} -> $newRelevance");
            suggestion.relevance = newRelevance;
          } else {
            int newRelevance = DART_RELEVANCE_COMMON_USAGE;
            _log.info("Completion not found: ${suggestion.completion}: ${suggestion.completion} -> $newRelevance");
            suggestion.relevance = newRelevance;
          }
        } else {
          _log.info("Element type can't be matched: ${element}");
        }
      }
  }
}

/**
 * An [AstVisitor] used to determine the best defining type of a node.
 */
class _BestTypeVisitor extends GeneralizingAstVisitor {
  /**
   * The entity which the completed text will replace (or which will be
   * displaced once the completed text is inserted).  This may be an AstNode or
   * a Token, or it may be null if the cursor is after all tokens in the file.
   * See field of the same name in [CompletionTarget].
   */
  final Object entity;

  _BestTypeVisitor(this.entity);

  DartType visitConstructorName(ConstructorName node) {
    if (node.period != null && node.name == entity) {
      TypeName typeName = node.type;
      if (typeName != null) {
        return typeName.type;
      }
    }
    return null;
  }

  DartType visitNode(AstNode node) {
    return null;
  }

  DartType visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.identifier == entity) {
      SimpleIdentifier prefix = node.prefix;
      if (prefix != null) {
        return prefix.bestType;
      }
    }
    return null;
  }

  DartType visitPropertyAccess(PropertyAccess node) {
    if (node.propertyName == entity) {
      Expression target = node.realTarget;
      if (target != null) {
        return target.bestType;
      }
    }
    return null;
  }
}
//
// log(String s) {
//   print ("${new DateTime.now().toIso8601String()}: $s");
//   // String _LOGFILE = "/Users/lukechurch/scratch-working/common_usage_sorter.log";
//   // new io.File(_LOGFILE).writeAsStringSync("${new DateTime.now().toIso8601String()}: $s \n", mode: io.FileMode.APPEND);
// }
