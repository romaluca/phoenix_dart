import 'dart:async';
/**
 *
 * Creates a timer that accepts a `timerCalc` function to perform
 * calculated timeout retries, such as exponential backoff.
 *
 * ## Examples
 *
 * ```javascript
 *    let reconnectTimer = new Timer(() => this.connect(), function(tries){
 *      return [1000, 5000, 10000][tries - 1] || 10000
 *    })
 *    reconnectTimer.scheduleTimeout() // fires after 1000
 *    reconnectTimer.scheduleTimeout() // fires after 5000
 *    reconnectTimer.reset()
 *    reconnectTimer.scheduleTimeout() // fires after 1000
 * ```
 * @param {Function} callback
 * @param {Function} timerCalc
 */
class PhoenixTimer {
  var callback;
  var timerCalc;
  Timer timer;
  var tries;

  PhoenixTimer(callback, timerCalc){
    this.callback  = callback;
    this.timerCalc = timerCalc;
    this.timer     = null;
    this.tries     = 0;
  }

  void reset(){
    this.tries = 0;
    timer.cancel();
  }

  /**
   * Cancels any previous scheduleTimeout and schedules callback
   */
  void scheduleTimeout(){
    this.timer?.cancel();
    this.timer = new Timer(new Duration(milliseconds: this.timerCalc(this.tries + 1)), () {
      this.tries = this.tries + 1;
      this.callback();
    });    
  }
}
