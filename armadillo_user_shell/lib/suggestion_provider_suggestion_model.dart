// Copyright 2016 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:apps.maxwell.services.suggestion/suggestion_display.fidl.dart'
    as maxwell;
import 'package:apps.maxwell.services.suggestion/suggestion_provider.fidl.dart'
    as maxwell;
import 'package:apps.maxwell.services.suggestion/user_input.fidl.dart'
    as maxwell;
import 'package:apps.modular.services.user/focus.fidl.dart';
import 'package:armadillo/interruption_overlay.dart';
import 'package:armadillo/story.dart';
import 'package:armadillo/story_cluster.dart';
import 'package:armadillo/story_cluster_id.dart';
import 'package:armadillo/story_model.dart';
import 'package:armadillo/suggestion.dart';
import 'package:armadillo/suggestion_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import 'hit_test_model.dart';

final Map<maxwell.SuggestionImageType, ImageType> _kImageTypeMap =
    <maxwell.SuggestionImageType, ImageType>{
  maxwell.SuggestionImageType.person: ImageType.circular,
  maxwell.SuggestionImageType.other: ImageType.rectangular,
};

/// Listens to a maxwell suggestion list.  As suggestions change it
/// notifies its [suggestionListener].
class _MaxwellSuggestionListenerImpl extends maxwell.SuggestionListener {
  final String prefix;
  final VoidCallback suggestionListener;
  final Map<String, Suggestion> _suggestions = <String, Suggestion>{};

  _MaxwellSuggestionListenerImpl({this.prefix, this.suggestionListener});

  List<Suggestion> get suggestions => _suggestions.values.toList();

  @override
  void onAdd(List<maxwell.Suggestion> suggestions) {
    suggestions.forEach(
      (maxwell.Suggestion suggestion) =>
          _suggestions[suggestion.uuid] = _convert(suggestion),
    );
    suggestionListener?.call();
  }

  @override
  void onRemove(String uuid) {
    _suggestions.remove(uuid);
    suggestionListener?.call();
  }

  @override
  void onRemoveAll() {
    _suggestions.clear();
    suggestionListener?.call();
  }
}

/// Called when an interruption occurs.
typedef void OnInterruptionAdded(Suggestion interruption);

/// Called when an interruption has been removed.
typedef void OnInterruptionRemoved(String id);

/// Listens for interruptions from maxwell.
class InterruptionListener extends maxwell.SuggestionListener {
  /// Called when an interruption occurs.
  final OnInterruptionAdded onInterruptionAdded;

  /// Called when an interruption is finished.
  final OnInterruptionRemoved onInterruptionRemoved;

  /// Called when all interruptions are finished.
  final VoidCallback onInterruptionsRemoved;

  /// Constructor.
  InterruptionListener({
    @required this.onInterruptionAdded,
    @required this.onInterruptionRemoved,
    @required this.onInterruptionsRemoved,
  });

  @override
  void onAdd(List<maxwell.Suggestion> suggestions) => suggestions.forEach(
        (maxwell.Suggestion suggestion) =>
            onInterruptionAdded(_convert(suggestion)),
      );

  @override
  void onRemove(String uuid) {
    // TODO(apwilson): decide what to do with a removed interruption.
    onInterruptionRemoved(uuid);
  }

  @override
  void onRemoveAll() {
    // TODO(apwilson): decide what to do with a removed interruption.
    onInterruptionsRemoved();
  }
}

Suggestion _convert(maxwell.Suggestion suggestion) {
  bool hasImage = suggestion.display.imageUrl?.isNotEmpty ?? false;
  return new Suggestion(
    id: new SuggestionId(suggestion.uuid),
    title: suggestion.display.headline,
    themeColor: new Color(suggestion.display.color),
    selectionType: SelectionType.closeSuggestions,
    icons: const <WidgetBuilder>[],
    image: hasImage
        ? (_) => new Image.network(
              suggestion.display.imageUrl,
              fit: BoxFit.cover,
            )
        : null,
    imageType: hasImage
        ? _kImageTypeMap[suggestion.display.imageType]
        : ImageType.circular,
  );
}

/// Creates a list of suggestions for the SuggestionList using the
/// [maxwell.SuggestionProvider].
class SuggestionProviderSuggestionModel extends SuggestionModel {
  // Controls how many suggestions we receive from maxwell's Ask suggestion
  // stream as well as indicates what the user is asking.
  final maxwell.AskControllerProxy _askControllerProxy =
      new maxwell.AskControllerProxy();

  final maxwell.SuggestionListenerBinding _askListenerBinding =
      new maxwell.SuggestionListenerBinding();

  // Listens for changes to maxwell's ask suggestion list.
  _MaxwellSuggestionListenerImpl _askListener;

  // Controls how many suggestions we receive from maxwell's Next suggestion
  // stream.
  final maxwell.NextControllerProxy _nextControllerProxy =
      new maxwell.NextControllerProxy();

  final maxwell.SuggestionListenerBinding _nextListenerBinding =
      new maxwell.SuggestionListenerBinding();

  // Listens for changes to maxwell's next suggestion list.
  _MaxwellSuggestionListenerImpl _nextListener;

  final maxwell.SuggestionListenerBinding _interruptionListenerBinding =
      new maxwell.SuggestionListenerBinding();

  /// The key for the interruption overlay.
  final GlobalKey<InterruptionOverlayState> interruptionOverlayKey;

  List<Suggestion> _currentSuggestions = const <Suggestion>[];
  final List<Suggestion> _currentInterruptions = <Suggestion>[];

  /// When the user is asking via text or voice we want to show the maxwell ask
  /// suggestions rather than the normal maxwell suggestion list.
  String _askText;
  bool _asking = false;

  /// Set from an external source - typically the UserShell.
  maxwell.SuggestionProviderProxy _suggestionProviderProxy;

  /// Set from an external source - typically the UserShell.
  FocusControllerProxy _focusController;

  /// Set from an external source - typically the UserShell.
  VisibleStoriesControllerProxy _visibleStoriesController;

  // Set from an external source - typically the UserShell.
  StoryModel _storyModel;

  StoryClusterId _lastFocusedStoryClusterId;

  final Set<VoidCallback> _focusLossListeners = new Set<VoidCallback>();

  /// Listens for changes to visible stories.
  final HitTestModel hitTestModel;

  /// Constructor.
  SuggestionProviderSuggestionModel({
    this.hitTestModel,
    this.interruptionOverlayKey,
  });

  /// Setting [suggestionProvider] triggers the loading on suggestions.
  /// This is typically set by the UserShell.
  set suggestionProvider(
    maxwell.SuggestionProviderProxy suggestionProviderProxy,
  ) {
    _suggestionProviderProxy = suggestionProviderProxy;
    _askListener = new _MaxwellSuggestionListenerImpl(
      prefix: 'ask',
      suggestionListener: _onAskSuggestionsChanged,
    );
    _nextListener = new _MaxwellSuggestionListenerImpl(
      prefix: 'next',
      suggestionListener: _onNextSuggestionsChanged,
    );
    _load();
  }

  /// Sets the [FocusController] called when focus changes.
  set focusController(FocusControllerProxy focusController) {
    _focusController = focusController;
  }

  /// Sets the [VisibleStoriesController] called when the list of visible
  /// stories changes.
  set visibleStoriesController(
    VisibleStoriesControllerProxy visibleStoriesController,
  ) {
    _visibleStoriesController = visibleStoriesController;
  }

  /// Sets the [StoryModel] used to get the currently focused and visible
  /// stories.
  set storyModel(StoryModel storyModel) {
    _storyModel = storyModel;
    storyModel.addListener(_onStoryClusterListChanged);
  }

  /// [listener] will be called when no stories are in focus.
  void addOnFocusLossListener(VoidCallback listener) {
    _focusLossListeners.add(listener);
  }

  /// Called when an interruption is no longer showing.
  void onInterruptionDismissal(
    Suggestion interruption,
    DismissalReason reason,
  ) {
    switch (reason) {
      case DismissalReason.snoozed:
      case DismissalReason.timedOut:
        _currentInterruptions.insert(0, interruption);
        notifyListeners();
        break;
      default:
        break;
    }
  }

  /// Called when an interruption has been removed.
  void _onInterruptionRemoved(String uuid) {
    _currentInterruptions.removeWhere(
      (Suggestion interruption) => interruption.id.value == uuid,
    );
    notifyListeners();
  }

  /// Called when an interruption has been removed.
  void _onInterruptionsRemoved() {
    _currentInterruptions.clear();
    notifyListeners();
  }

  void _load() {
    _suggestionProviderProxy.initiateAsk(
      _askListenerBinding.wrap(_askListener),
      _askControllerProxy.ctrl.request(),
    );
    _askControllerProxy.setResultCount(20);

    _suggestionProviderProxy.subscribeToNext(
      _nextListenerBinding.wrap(_nextListener),
      _nextControllerProxy.ctrl.request(),
    );
    _nextControllerProxy.setResultCount(20);

    _suggestionProviderProxy.subscribeToInterruptions(
      _interruptionListenerBinding.wrap(
        new InterruptionListener(
          onInterruptionAdded: (Suggestion interruption) =>
              interruptionOverlayKey.currentState
                  .onInterruptionAdded(interruption),
          onInterruptionRemoved: (String uuid) {
            interruptionOverlayKey.currentState.onInterruptionRemoved(uuid);
            _onInterruptionRemoved(uuid);
          },
          onInterruptionsRemoved: () {
            interruptionOverlayKey.currentState.onInterruptionsRemoved();
            _onInterruptionsRemoved();
          },
        ),
      ),
    );
  }

  @override
  List<Suggestion> get suggestions {
    if (_asking) {
      return new List<Suggestion>.from(_currentSuggestions);
    }
    List<Suggestion> suggestions = new List<Suggestion>.from(
      _currentInterruptions,
    );
    suggestions.addAll(_currentSuggestions);
    return suggestions;
  }

  @override
  void onSuggestionSelected(Suggestion suggestion) {
    _suggestionProviderProxy.notifyInteraction(
      suggestion.id.value,
      new maxwell.Interaction()..type = maxwell.InteractionType.selected,
    );
  }

  @override
  set askText(String text) {
    if (_askText != text) {
      _askText = text;
      _askControllerProxy
          .setUserInput(new maxwell.UserInput()..text = text ?? '');
    }
  }

  @override
  set asking(bool asking) {
    if (_asking != asking) {
      _asking = asking;
      if (_asking) {
        _currentSuggestions = _askListener.suggestions;
      } else {
        _currentSuggestions = _nextListener.suggestions;
        _askControllerProxy.setUserInput(new maxwell.UserInput()..text = '');
      }
      notifyListeners();
    }
  }

  @override
  void storyClusterFocusChanged(StoryCluster storyCluster) {
    _lastFocusedStoryCluster?.removeStoryListListener(_onStoryListChanged);
    storyCluster?.addStoryListListener(_onStoryListChanged);
    _lastFocusedStoryClusterId = storyCluster?.id;
    _onStoryListChanged();
  }

  void _onStoryClusterListChanged() {
    if (_lastFocusedStoryClusterId != null) {
      if (_lastFocusedStoryCluster == null) {
        _lastFocusedStoryClusterId = null;
        _onStoryListChanged();
        _focusLossListeners.forEach((VoidCallback listener) => listener());
      }
    }
  }

  void _onStoryListChanged() {
    _focusController.set(_lastFocusedStoryCluster?.focusedStoryId?.value);

    List<String> visibleStoryIds = _lastFocusedStoryCluster?.stories
            ?.map<String>((Story story) => story.id.value)
            ?.toList() ??
        <String>[];
    hitTestModel.onVisibleStoriesChanged(visibleStoryIds);
    _visibleStoriesController.set(visibleStoryIds);
  }

  StoryCluster get _lastFocusedStoryCluster {
    if (_lastFocusedStoryClusterId == null) {
      return null;
    }
    Iterable<StoryCluster> storyClusters = _storyModel.storyClusters.where(
      (StoryCluster storyCluster) =>
          storyCluster.id == _lastFocusedStoryClusterId,
    );
    if (storyClusters.isEmpty) {
      return null;
    }
    assert(storyClusters.length == 1);
    return storyClusters.first;
  }

  void _onAskSuggestionsChanged() {
    if (_asking) {
      _currentSuggestions = _askListener.suggestions;
      notifyListeners();
    }
  }

  void _onNextSuggestionsChanged() {
    if (!_asking) {
      _currentSuggestions = _nextListener.suggestions;
      notifyListeners();
    }
  }
}
