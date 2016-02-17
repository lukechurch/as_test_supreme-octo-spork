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
import 'package:smart/completion_model/feature_vector.dart' as smart_feature_vector;

import 'package:smart/completion_server/feature_server.dart' as smart_feature_server;
import 'package:smart/completion_model/ast_extractors.dart' as smart_model_extractor;
import 'package:smart/completion_server/log_client.dart' as client_log;
import 'package:logging/logging.dart' as logging;

import 'package:path/path.dart' as path;

part 'common_usage_sorter.g.dart';

smart_model.Model model;
logging.Logger logger;

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
      Iterable<CompletionSuggestion> suggestions) {
    _update(request, suggestions);
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
  void _update(
      CompletionRequest request, Iterable<CompletionSuggestion> suggestions) {
        var target = _getCompletionTarget(request);

        log("About to _update: $request");
        log("Model $model");

        List<smart_model.CompletionResult> completionScores;
        smart_feature_vector.FeatureVector features;


        try {
          String homeDir = io.Platform.environment["HOME"];
          String workingPath = path.join(homeDir, "feature_files");


          if (model == null) {
            smart_feature_server.FeatureServer featureServer = new
              smart_feature_server.FeatureServer.fromPaths(
                path.join(workingPath, "completion_count.json"),
                path.join(workingPath, "packed_model.smart_complete")
              );

            model = new smart_model.Model(featureServer);
          }

          log("Request Target: $request");
          log("target.containingNode: ${target.containingNode}");
          log("target.entity: ${target.entity}");
          log("targetRuntimeType: ${target.containingNode.runtimeType}");

          Stopwatch sw = new Stopwatch()..start();

          if (target.containingNode is MethodInvocation) {
            log("Method invocation");
            var node = target.containingNode as MethodInvocation;
            features = smart_model_extractor.featuresFromMethodInvocation(node);
          } else if (target.containingNode is PropertyAccess) {
            log("Method property access");
            var node = target.containingNode as PropertyAccess;
            features = smart_model_extractor.featuresFromPropertyAccess(node);
          } else if (target.containingNode is PrefixedIdentifier) {
            log("Method prefixed identifier");
            var node = target.containingNode as PrefixedIdentifier;
            features = smart_model_extractor.featuresFromPrefixedIdentifier(node);
          }

          log("Features for Node");
          log(features.toJsonString());

          completionScores = model.scoreCompletionOrder(features);

          // log("Completion scores");
          // log(convert.JSON.encode(completionScores));

          log ("Extraction complete: ${sw.elapsedMilliseconds}/ms");

        } catch (e, st) {
          log ("Crash: $e \n $st");
        }
        log ("Ordered completion List");
        log ("\n${completionScores.join("\n")}");
        List<String> completionList = completionScores.map((c) => c.completion).toList();


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
            suggestion.relevance = DART_RELEVANCE_COMMON_USAGE - index;
          }
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

log(String s) {
  if (logger == null) {
    logger = new logging.Logger("common_usage_sorter");
    client_log.bindLogServer(logger);
  }

  logger.info(s);

  // print ("${new DateTime.now().toIso8601String()}: $s");
  // String _LOGFILE = "/Users/lukechurch/scratch-working/common_usage_sorter.log";
  // new io.File(_LOGFILE).writeAsStringSync("${new DateTime.now().toIso8601String()}: $s \n", mode: io.FileMode.APPEND);
}
