
s = Server.new();
Server.default.options.inDevice_("Microfono MacBook Air");
Server.default.options.outDevice_("Altoparlanti MacBook Air");
s.reboot;


"open -a 'Audio MIDI Setup'".unixCmd; // execute this to launch it


NetAddr("127.0.0.1", 57120);

(
OSCdef('OSCReceiver',
	{
		arg msg;

		var complexity, wet, freeze;

		complexity = msg[1];
		wet = msg[2];
		freeze = msg[3];
		postf("complexity %, wet %, freeze %\n", complexity, wet, freeze);

	},
	'\arduino/params';
 )
)
(
OSCdef('OSCReceiver2',
	{
		arg msg;

		var tonality, mode;

		tonality = msg[1];
		mode = msg[2];
		postf("tonality %, mode %, freeze %\n", tonality, mode);

	},
	'\chord/complexity';
 )
)