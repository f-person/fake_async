// Copyright 2014 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';
import 'package:quiver/time.dart';

/// The type of a microtask callback.
typedef void _Microtask();

/// A class that mocks out the passage of time within a [Zone].
///
/// Test code can be passed as a callback to [run], which causes it to be run in
/// a [Zone] which fakes timer and microtask creation, such that they are run
/// during calls to [elapse] which simulates the asynchronous passage of time.
///
/// The synchronous passage of time (as from blocking or expensive calls) can
/// also be simulated using [elapseBlocking].
class FakeAsync {
  /// The amount of fake time that's elapsed since this [FakeAsync] was
  /// created.
  var _elapsed = Duration.ZERO;

  /// The fake time at which the current call to [elapse] will finish running.
  ///
  /// This is `null` if there's no current call to [elapse].
  Duration _elapsingTo;

  /// The queue of microtasks that are scheduled to run when fake time
  /// progresses.
  final _microtasks = new Queue<_Microtask>();

  /// All timers created within [run].
  final _timers = new Set<_FakeTimer>();

  /// The number of active periodic timers created within a call to [run].
  int get periodicTimerCount =>
      _timers.where((timer) => timer._isPeriodic).length;

  /// The number of active non-periodic timers created within a call to [run].
  int get nonPeriodicTimerCount =>
      _timers.where((timer) => !timer._isPeriodic).length;

  /// The number of pending microtasks scheduled within a call to [run].
  int get microtaskCount => _microtasks.length;

  /// Returns a fake [Clock] whose time can is elapsed by calls to [elapse] and
  /// [elapseBlocking].
  ///
  /// The returned clock starts at [initialTime] plus the fake time that's
  /// already been elapsed. Further calls to [elapse] and [elapseBlocking] will
  /// advance the clock as well.
  Clock getClock(DateTime initialTime) =>
      new Clock(() => initialTime.add(_elapsed));

  /// Simulates the asynchronous passage of time.
  ///
  /// Throws an [ArgumentError] if [duration] is negative. Throws a [StateError]
  /// if a previous call to [elapse] has not yet completed.
  ///
  /// Any timers created within [run] will fire if their time is within
  /// [duration]. The microtask queue is processed before and after each timer
  /// fires.
  void elapse(Duration duration) {
    if (duration.inMicroseconds < 0) {
      throw new ArgumentError.value(
          duration, 'duration', 'may not be negative');
    } else if (_elapsingTo != null) {
      throw new StateError('Cannot elapse until previous elapse is complete.');
    }

    _elapsingTo = _elapsed + duration;
    _fireTimersWhile((next) => next._nextCall <= _elapsingTo);
    _elapseTo(_elapsingTo);
    _elapsingTo = null;
  }

  /// Simulates the synchronous passage of time, resulting from blocking or
  /// expensive calls.
  ///
  /// Neither timers nor microtasks are run during this call, but if this is
  /// called within [elapse] they may fire afterwards.
  ///
  /// Throws an [ArgumentError] if [duration] is negative.
  void elapseBlocking(Duration duration) {
    if (duration.inMicroseconds < 0) {
      throw new ArgumentError('Cannot call elapse with negative duration');
    }

    _elapsed += duration;
    if (_elapsingTo != null && _elapsed > _elapsingTo) _elapsingTo = _elapsed;
  }

  /// Runs [callback] in a [Zone] where all asynchrony is controlled by [this].
  ///
  /// All [Future]s, [Stream]s, [Timer]s, microtasks, and other time-based
  /// asynchronous features used within [callback] are controlled by calls to
  /// [elapse] rather than the passing of real time.
  ///
  /// Calls [callback] with `this` as argument and returns its result.
  T run<T>(T callback(FakeAsync self)) => runZoned(() => callback(this),
      zoneSpecification: new ZoneSpecification(
          createTimer: (_, __, ___, duration, callback) =>
              _createTimer(duration, callback, false),
          createPeriodicTimer: (_, __, ___, duration, callback) =>
              _createTimer(duration, callback, true),
          scheduleMicrotask: (_, __, ___, microtask) =>
              _microtasks.add(microtask)));

  /// Runs all pending microtasks scheduled within a call to [run] until there
  /// are no more microtasks scheduled.
  ///
  /// Does not run timers.
  void flushMicrotasks() {
    while (_microtasks.isNotEmpty) {
      _microtasks.removeFirst()();
    }
  }

  /// Elapses time until there are no more active timers.
  ///
  /// If `flushPeriodicTimers` is `true` (the default), this will repeatedly run
  /// periodic timers until they're explicitly canceled. Otherwise, this will
  /// stop when the only active timers are periodic.
  ///
  /// The [timeout] controls how much fake time may elapse before a [StateError]
  /// is thrown. This ensures that a periodic timer doesn't cause this method to
  /// deadlock. It defaults to one hour.
  void flushTimers({Duration timeout, bool flushPeriodicTimers: true}) {
    timeout ??= const Duration(hours: 1);

    var absoluteTimeout = _elapsed + timeout;
    _fireTimersWhile((timer) {
      if (timer._nextCall > absoluteTimeout) {
        // TODO(nweiz): Make this a [TimeoutException].
        throw new StateError(
            'Exceeded timeout ${timeout} while flushing timers');
      }

      if (flushPeriodicTimers) return _timers.isNotEmpty;

      // Continue firing timers until the only ones left are periodic *and*
      // every periodic timer has had a change to run against the final
      // value of [_elapsed].
      return _timers
          .any((timer) => !timer._isPeriodic || timer._nextCall <= _elapsed);
    });
  }

  /// Invoke the callback for each timer until [predicate] returns `false` for
  /// the next timer that would be fired.
  ///
  /// Microtasks are flushed before and after each timer is fired. Before each
  /// timer fires, [_elapsed] is updated to the appropriate duration.
  void _fireTimersWhile(bool predicate(_FakeTimer timer)) {
    flushMicrotasks();
    while (true) {
      if (_timers.isEmpty) break;

      var timer = minBy(_timers, (timer) => timer._nextCall);
      if (!predicate(timer)) break;

      _elapseTo(timer._nextCall);
      timer._fire();
      flushMicrotasks();
    }
  }

  /// Creates a new timer controlled by [this] that fires [callback] after
  /// [duration] (or every [duration] if [periodic] is `true`).
  Timer _createTimer(Duration duration, Function callback, bool periodic) {
    var timer = new _FakeTimer(duration, callback, periodic, this);
    _timers.add(timer);
    return timer;
  }

  /// Sets [_elapsed] to [to] if [to] is longer than [_elapsed].
  void _elapseTo(Duration to) {
    if (to > _elapsed) _elapsed = to;
  }
}

/// An implementation of [Timer] that's controlled by a [FakeAsync].
class _FakeTimer implements Timer {
  /// If this is periodic, the time that should elapse between firings of this
  /// timer.
  ///
  /// This is not used by non-periodic timers.
  final Duration _duration;

  /// The callback to invoke when the timer fires.
  ///
  /// For periodic timers, this is a `void Function(Timer)`. For non-periodic
  /// timers, it's a `void Function()`.
  final Function _callback;

  /// Whether this is a periodic timer.
  final bool _isPeriodic;

  /// The [FakeAsync] instance that controls this timer.
  final FakeAsync _async;

  /// The value of [FakeAsync._elapsed] at (or after) which this timer should be
  /// fired.
  Duration _nextCall;

  // TODO: Dart 2.0 requires this method to be implemented.
  int get tick {
    throw new UnimplementedError("tick");
  }

  _FakeTimer(Duration duration, this._callback, this._isPeriodic, this._async)
      : _duration = duration < Duration.ZERO ? Duration.ZERO : duration {
    _nextCall = _async._elapsed + _duration;
  }

  bool get isActive => _async._timers.contains(this);

  void cancel() => _async._timers.remove(this);

  /// Fires this timer's callback and updates its state as necessary.
  void _fire() {
    assert(isActive);
    if (_isPeriodic) {
      _callback(this);
      _nextCall += _duration;
    } else {
      cancel();
      _callback();
    }
  }
}
