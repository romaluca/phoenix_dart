import './channel.dart';
import './timer.dart';
/**
 * Initializes the Push
 * @param {Channel} channel - The Channel
 * @param {string} event - The event, for example `"phx_join"`
 * @param {Object} payload - The payload, for example `{user_id: 123}`
 * @param {number} timeout - The push timeout in milliseconds
 */
class Push {

  Channel channel;
  String event;
  Map payload;  
  Map receivedResp;
  num timeout;
  PhoenixTimer timeoutTimer;
  var recHooks;
  bool sent;
  var ref;
  var refEvent;


  Push(channel, event, Map payload, timeout){
    this.channel      = channel;
    this.event        = event;
    this.payload      = payload ?? new Map();
    this.receivedResp = null;
    this.timeout      = timeout;
    this.timeoutTimer = null;
    this.recHooks     = [];
    this.sent         = false;
  }

  /**
   *
   * @param {number} timeout
   */
  void resend(timeout){
    this.timeout = timeout;
    this.reset();
    this.send();
  }

  /**
   *
   */
  void send(){ 
    if(!this.hasReceived("timeout")){
      this.startTimeout();
      this.sent = true;
      this.channel.socket.push({
        "topic": this.channel.topic,
        "event": this.event,
        "payload": this.payload,
        "ref": this.ref,
        "join_ref": this.channel.joinRef()
      });
    }
  }

  /**
   *
   * @param {*} status
   * @param {*} callback
   */
  Push receive(status, callback){
    if(this.hasReceived(status)){
      callback(this.receivedResp["response"]);
    }

    this.recHooks.push({status: status, callback: callback});
    return this;
  }


  // private

  void reset(){
    this.cancelRefEvent();
    this.ref          = null;
    this.refEvent     = null;
    this.receivedResp = null;
    this.sent         = false;
  }

  void matchReceive(payload){
    var status = payload["status"];
    var response = payload["response"];
    //var ref = payload["ref"];
    this.recHooks.filter( (h) => h.status == status )
                 .forEach( (h) => h.callback(response));
  }

  void cancelRefEvent(){ 
    if(this.refEvent)
      this.channel.off(this.refEvent);
  }

  void cancelTimeout(){
    this.timeoutTimer.reset();
    this.timeoutTimer = null;
  }

  void startTimeout(){ 
    if(this.timeoutTimer != null)
      this.cancelTimeout();
    this.ref      = this.channel.socket.makeRef();
    this.refEvent = this.channel.replyEventName(this.ref);

    this.channel.on(this.refEvent, (Map payload) {
      this.cancelRefEvent();
      this.cancelTimeout();
      this.receivedResp = payload;
      this.matchReceive(payload);
    });

    this.timeoutTimer = new PhoenixTimer(() {
      this.trigger("timeout", new Map());
    }, this.timeout);
    this.timeoutTimer.scheduleTimeout();

  }

  bool hasReceived(status){
    return this.receivedResp != null && this.receivedResp["status"] == status;
  }

  void trigger(status, Map response){
    this.channel.trigger(this.refEvent, {status: status, response: response});
  }
}
