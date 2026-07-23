'use strict';
'require view';
'require rpc';
'require ui';

var STAGE2_URL = 'http://192.168.1.1:18080/';

var callStartStock = rpc.declare({
	object: 'matrix',
	method: 'start',
	expect: { }
});

var callStatus = rpc.declare({
	object: 'matrix',
	method: 'status',
	expect: { }
});

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(data) {
		var redirectStarted = false;

		var logBox = E('pre', {
			'id': 'matrix-log',
			'style': 'background:#111;color:#eee;padding:12px;min-height:320px;white-space:pre-wrap;overflow:auto'
		}, [ data.log || 'No status yet.' ]);

		var stockButton = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'style': 'margin-right:12px'
		}, [ _('Start Stage 2') ]);

		var stage2Link = E('a', {
			'style': 'font-weight:bold'
		}, [ _('Stage 2 URL = 192.168.1.1:18080') ]);

		function showStage2Message() {
			logBox.textContent =
				'Stage 2 will be starting at 192.168.1.1:18080\n\n' +
				'The router is rebooting into Matrix ...\n' +
				'This page will redirect automatically, do not close this web page\n\n' +
				'If it does not open after two minutes, check 192.168.1.1:18080 in new web window\n' +
				STAGE2_URL + '\n';
		}

		function redirectToStage2() {
			if (redirectStarted)
				return;

			redirectStarted = true;

			window.setTimeout(function() {
				window.location.href = STAGE2_URL + '?v=' + Date.now();
			}, 60000);
		}

		function startConversion() {
			if (!window.confirm(_('Boot Matrix Stage 2 recovery to continue flashing? Do not power off the router.')))
				return;

			stockButton.disabled = true;
			stockButton.textContent = _('Starting Matrix recovery...');

			showStage2Message();
			redirectToStage2();

			callStartStock().then(function(res) {
				if (!res || res.ok !== true) {
					ui.addNotification(null,
						E('p', {}, [ res && res.message ? res.message : _('Failed to start Matrix recovery') ]),
						'danger'
					);
				}
				else {
					ui.addNotification(null,
						E('p', {}, [ res.message || _('Matrix recovery started') ]),
						'info'
					);
				}
			}).catch(function(err) {
				/*
				 * This is normal if the router is already rebooting.
				 * 
				 */
				logBox.textContent += '\nRPC connection ended: ' + err + '\nRedirecting to Stage 2 soon...\n';
			});
		}

		stockButton.addEventListener('click', function(ev) {
			ev.preventDefault();
			startConversion();
		});

		function updateLog() {
			if (redirectStarted)
				return;

			callStatus().then(function(res) {
				if (res && res.log)
					logBox.textContent = res.log;
			}).catch(function() {
				logBox.textContent = 'Unable to read Matrix status.';
			});
		}

		window.setInterval(updateLog, 1500);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('Matrix OpenWrt Converter') ]),

			E('div', { 'class': 'alert-message warning' }, [
				E('strong', {}, [ _('Warning: ') ]),
				_('Do not power off the router while staging Matrix recovery or converting layout.')
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ _('OpenWrt stock or OEM layout conversion') ]),
				E('p', {}, [
					_('Conversion will start in Stage 2')
				]),
				E('p', {}, [ stockButton ]),
				E('p', {}, [ stage2Link ])
			]),

			E('h3', {}, [ _('Status') ]),
			logBox
		]);
	}
});