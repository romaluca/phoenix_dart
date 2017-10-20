import 'utils.dart';
import 'ajax.dart';


class LongPoll {
  String endPoint;
  String token;
  bool skipHeartbeat; 
  var onopen;
  var onerror;
  var onmessage;
  var onclose;
  String pollEndpoint;
  SOCKET_STATES readyState;

  LongPoll(endPoint){
    this.endPoint        = null;
    this.token           = null;
    this.skipHeartbeat   = true;
    this.onopen          = (){}; // noop
    this.onerror         = (){}; // noop
    this.onmessage       = (){}; // noop
    this.onclose         = (){}; // noop
    this.pollEndpoint    = this.normalizeEndpoint(endPoint);
    this.readyState      = SOCKET_STATES.connecting;

    this.poll();
  }

  String normalizeEndpoint(endPoint){
    return(endPoint
      .replace("ws://", "http://")
      .replace("wss://", "https://")
      .replace(new RegExp("(.*)\/" + TRANSPORTS.websocket), "$1/" + TRANSPORTS.longpoll));
  }

  endpointURL(){
    return Ajax.appendParams(this.pollEndpoint, {token: this.token});
  }

  closeAndRetry(){
    this.close();
    this.readyState = SOCKET_STATES.connecting;
  }

  ontimeout(){
    this.onerror("timeout");
    this.closeAndRetry();
  }

  poll(){
    if(this.readyState == SOCKET_STATES.open || this.readyState == SOCKET_STATES.connecting){ 

      Ajax.request("GET", this.endpointURL(), "application/json", null, this.timeout, this.ontimeout.bind(this), (resp) {
        int status;
        if(resp){
          status = resp["status"];
          String token = resp["token"];
          //var messages = resp["messages"];
          this.token = token;
        } else{
          status = 0;
        }

        switch(status){
          case 200:
            messages.forEach((msg) => this.onmessage({"data": msg}));
            this.poll();
            break;
          case 204:
            this.poll();
            break;
          case 410:
            this.readyState = SOCKET_STATES.open;
            this.onopen();
            this.poll();
            break;
          case 0:
          case 500:
            this.onerror();
            this.closeAndRetry();
            break;
          default: throw("unhandled poll status ${status}");
        }
      });
    }
  }

  send(body){
    Ajax.request("POST", this.endpointURL(), "application/json", body, this.timeout, this.onerror.bind(this, "timeout"), (resp) {
      if(resp == null || resp.status != 200){
        this.onerror(resp && resp.status);
        this.closeAndRetry();
      }
    });
  }

  close(code, reason){
    this.readyState = SOCKET_STATES.closed;
    this.onclose();
  }
}
