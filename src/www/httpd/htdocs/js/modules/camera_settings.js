var APP = APP || {};

APP.camera_settings = (function($) {

    var motionStatusTimer = null;
    var customSupported = false;
    var firmwareOptionsSet = false;
    var savedMotionSensitivity = '5';
    var motionSamples = [];
    var lastSampleTime = null;
    var maskSupported = false;
    var maskCells = '0'.repeat(240);
    var maskActivity = '';
    var maskImage = null;
    var maskPaint = null;
    var maskCursor = 0;

    function init() {
        customSupported = false;
        firmwareOptionsSet = false;
        motionSamples = [];
        lastSampleTime = null;
        maskSupported = false; maskCells = '0'.repeat(240); maskActivity = ''; maskImage = null;
        maskPaint = null; maskCursor = 0;
        registerEventHandler();
        fetchConfigs();
        startMotionStatusPolling();
        updatePage();
    }

    function registerEventHandler() {
        $(document).off(".cameraSettingsModule");
        $(document).on("click.cameraSettingsModule", '#button-save', function(e) {
            saveConfigs();
        });
        $(document).on("change.cameraSettingsModule", '#NIGHTVISION_MODE', updateNightvisionControls);
        $(document).on("change.cameraSettingsModule input.cameraSettingsModule", '#MOTION_CUSTOM, #MOTION_START_SAMPLES, #MOTION_POLL_INTERVAL', updateMotionControls);
        $(document).on("click.cameraSettingsModule", '#motion-copy-preset', copyMotionPreset);
        $(document).on("click.cameraSettingsModule", '#motion-mask-clear, #motion-mask-all', function() {
            maskCells = (this.id === 'motion-mask-all' ? '1' : '0').repeat(240); drawMask();
        });
        $(document).on("click.cameraSettingsModule", '#motion-mask-snapshot', function() {
            var image = new Image();
            image.onload = function() { maskImage = image; drawMask(); };
            image.onerror = function() { $('#motion-mask-status').text('Snapshot unavailable; you can still edit the grid.'); };
            image.src = 'cgi-bin/snapshot.sh?res=low&nocache=' + Date.now();
        });
        $(document).on("pointerdown.cameraSettingsModule pointermove.cameraSettingsModule", '#motion-mask-canvas', function(e) {
            var event = e.originalEvent;
            if (e.type === 'pointermove' && maskPaint === null) return;
            if (e.type === 'pointerdown' && event.button !== 0) return;
            var rect = this.getBoundingClientRect();
            var col = Math.max(0, Math.min(19, Math.floor((event.clientX - rect.left) * 20 / rect.width)));
            var row = Math.max(0, Math.min(11, Math.floor((event.clientY - rect.top) * 12 / rect.height)));
            maskCursor = row * 20 + col;
            if (e.type === 'pointerdown') { maskPaint = maskCells[maskCursor] === '1' ? '0' : '1'; this.setPointerCapture(event.pointerId); this.focus(); }
            maskCells = maskCells.slice(0, maskCursor) + maskPaint + maskCells.slice(maskCursor + 1);
            drawMask(); e.preventDefault();
        });
        $(document).on("pointerup.cameraSettingsModule pointercancel.cameraSettingsModule", function() { maskPaint = null; });
        $(document).on("keydown.cameraSettingsModule", '#motion-mask-canvas', function(e) {
            var moves = {ArrowLeft:-1, ArrowRight:1, ArrowUp:-20, ArrowDown:20};
            if (moves[e.key]) maskCursor = Math.max(0, Math.min(239, maskCursor + moves[e.key]));
            else if (e.key === ' ') maskCells = maskCells.slice(0, maskCursor) + (maskCells[maskCursor] === '1' ? '0' : '1') + maskCells.slice(maskCursor + 1);
            else return;
            drawMask(); e.preventDefault();
        });
    }

    function fetchConfigs() {
        var loadingStatusElem = $('#loading-status');
        loadingStatusElem.text("Loading...");

        $.ajax({
            type: "GET",
            url: 'cgi-bin/get_configs.sh?conf=camera',
            dataType: "json",
            success: function(response) {
                loadingStatusElem.fadeOut(500);
                savedMotionSensitivity = response.MOTION_SENSITIVITY || '5';
                maskCells = /^[01]{240}$/.test(response.MOTION_MASK_CELLS || '') ? response.MOTION_MASK_CELLS : '0'.repeat(240);
                $('#MOTION_MASK_VECTOR_PIXELS').val(response.MOTION_MASK_VECTOR_PIXELS || '1');
                $('#MOTION_MASK_DIFFERENCE').val(response.MOTION_MASK_DIFFERENCE || '12');

                $.each(response, function(key, state) {
                    if (key === "MOTION_SENSITIVITY" || key === "SOUND_SENSITIVITY" || key === "CRUISE" || key === "NIGHTVISION_MODE") {
                        $('select[data-key="' + key + '"]').prop('value', state);
                    } else if (key === "NIGHTVISION_THRESHOLD" || /^MOTION_(START_THRESHOLD|STOP_THRESHOLD|START_SAMPLES|STOP_DELAY|POLL_INTERVAL)$/.test(key)) {
                        $('#' + key).val(state);
                    } else {
                        $('input[type="checkbox"][data-key="' + key + '"]').prop('checked', state === 'yes');
                    }
                });
                if (!response.NIGHTVISION_MODE) {
                    $('#NIGHTVISION_MODE').val(response.IR === 'no' ? 'off' : 'auto');
                }
                updateNightvisionControls();
                if (firmwareOptionsSet) $('#MOTION_SENSITIVITY').val(firmwareSensitivity(savedMotionSensitivity));
                updateMotionControls();
                drawMask();
            },
            error: function(response) {
                loadingStatusElem.text("Unable to load settings");
                console.log('error', response);
            }
        });
    }

    function startMotionStatusPolling() {
        if (motionStatusTimer) {
            clearTimeout(motionStatusTimer);
            motionStatusTimer = null;
        }

        function poll() {
            if (!$('#motion-backend-status').length) {
                motionStatusTimer = null;
                return;
            }
            if (!document.hidden) {
                fetchMotionStatus();
                fetchNightvisionStatus();
            }
            motionStatusTimer = setTimeout(poll, 2000);
        }

        poll();
    }

    function fetchMotionStatus() {
        $.ajax({
            type: "GET",
            url: 'cgi-bin/motion_status.sh',
            dataType: "json",
            cache: false,
            success: function(data) {
                if (data.error) return;

                $('#motion-backend-status').text(data.backend_label || data.backend || 'Unknown');
                $('#motion-runtime-status').text('Service: ' + (data.status || 'unknown') + ', state: ' + (data.state || 'unknown'));
                if (data.metrics && data.metrics.ipc_pending) {
                    $('#motion-runtime-status').append(' — Recorder notification pending; detection continues.');
                }
                if (data.metrics && data.metrics.state_pending) {
                    $('#motion-runtime-status').append(' — Motion status update pending.');
                }
                customSupported = data.custom_supported === true;
                maskSupported = data.mask_supported === true;
                $('#motion-details-panel').prop('hidden', !(customSupported || maskSupported));
                $('#motion-mask-panel').prop('hidden', !maskSupported);
                $('#motion-mask-encoder-settings').prop('hidden', data.model === 'y28ga');
                $('#motion-mask-iva-description').prop('hidden', data.model !== 'y28ga');
                $('#motion-iva-metadata-description').prop('hidden', data.model !== 'y28ga');
                $('#motion-encoder-reading-description').prop('hidden', !customSupported);
                $('#motion-custom-panel').prop('hidden', !customSupported);
                $('#motion-firmware-limit').prop('hidden', data.backend !== 'ipc-events');
                if (data.backend === 'ipc-events' && !firmwareOptionsSet) {
                    $('#MOTION_SENSITIVITY').html('<option value="2">Low</option><option value="5">Medium</option><option value="9">High</option>')
                        .val(firmwareSensitivity(savedMotionSensitivity));
                    firmwareOptionsSet = true;
                }
                updateMotionControls();
                renderMotionMetrics(data);

                if (data.sensitivity_supported) {
                    $('#MOTION_SENSITIVITY').prop('disabled', false);
                    $('#motion-sensitivity-description').text(data.backend === 'ipc-events' ?
                        'Firmware sensitivity: ' + data.firmware_sensitivity + '. Low, medium, and high are the three supported levels.' :
                        ($('#MOTION_CUSTOM').prop('checked') ? 'Custom thresholds replace the sensitivity preset.' : 'Sensitivity for the active local motion detector.'));
                    if (customSupported && $('#MOTION_CUSTOM').prop('checked')) $('#MOTION_SENSITIVITY').prop('disabled', true);
                } else {
                    $('#MOTION_SENSITIVITY').prop('disabled', true);
                    if (data.backend === 'ipc-events') {
                        $('#motion-sensitivity-description').text('This model uses the generic firmware IVA detector with local IPC events. Sensitivity is mapped to the firmware detector; legacy AI motion remains disabled.');
                    } else {
                        $('#motion-sensitivity-description').text('This backend uses firmware-native sensitivity; the legacy YI sensitivity control is intentionally not exposed.');
                    }
                }
            },
            error: function(response) {
                $('#motion-backend-status').text('Status unavailable');
                $('#motion-runtime-status').text('');
            }
        });
    }

    function firmwareSensitivity(value) {
        return Number(value) <= 3 ? '2' : Number(value) >= 8 ? '9' : '5';
    }

    function drawMask() {
        var canvas = document.getElementById('motion-mask-canvas');
        if (!canvas) return;
        var ctx = canvas.getContext('2d');
        ctx.clearRect(0, 0, 640, 360);
        if (maskImage) ctx.drawImage(maskImage, 0, 0, 640, 360);
        for (var i = 0; i < 240; i++) {
            var x = (i % 20) * 32, y = Math.floor(i / 20) * 30;
            if (maskCells[i] === '1') { ctx.fillStyle = 'rgba(220,38,38,0.55)'; ctx.fillRect(x, y, 32, 30); }
            ctx.strokeStyle = maskActivity[i] === '1' ? '#4ade80' : 'rgba(200,200,200,0.5)';
            ctx.lineWidth = maskActivity[i] === '1' ? 3 : 1; ctx.strokeRect(x + 1, y + 1, 30, 28);
        }
        if (document.activeElement === canvas) {
            ctx.strokeStyle = '#fff'; ctx.lineWidth = 3;
            ctx.strokeRect((maskCursor % 20) * 32 + 4, Math.floor(maskCursor / 20) * 30 + 4, 24, 22);
        }
    }

    function updateMotionControls() {
        var custom = customSupported && $('#MOTION_CUSTOM').prop('checked');
        $('#motion-custom-fields').prop('disabled', !custom);
        if (customSupported) $('#MOTION_SENSITIVITY').prop('disabled', custom);
        var interval = Number($('#MOTION_POLL_INTERVAL').val());
        var samples = Number($('#MOTION_START_SAMPLES').val());
        $('#motion-start-timing').text('Consecutive samples above the start threshold. Approximate confirmation time: ' +
            ((samples - 1) * interval) + '\u2013' + (samples * interval) + ' ms, plus camera response time.');
    }

    function copyMotionPreset() {
        var presets = [[15,1.5,5],[10,1,5],[7,0.7,4],[5,0.5,4],[3,0.3,3],
            [2,0.2,3],[1.2,0.15,3],[0.8,0.15,2],[0.5,0.15,2],[0.25,0.15,2]];
        var preset = presets[Number($('#MOTION_SENSITIVITY').val()) - 1] || presets[4];
        $('#MOTION_START_THRESHOLD').val(preset[0].toFixed(2));
        $('#MOTION_STOP_THRESHOLD').val(preset[1].toFixed(2));
        $('#MOTION_START_SAMPLES').val(preset[2]);
        $('#MOTION_STOP_DELAY').val(2000);
        $('#MOTION_POLL_INTERVAL').val(100);
        $('#MOTION_STOP_REQUIRE_ZERO').prop('checked', true);
        $('#MOTION_CUSTOM').prop('checked', true);
        updateMotionControls();
    }

    function renderMotionMetrics(data) {
        if (!customSupported) {
            renderIvaMetrics(data);
            return;
        }
        var c = data.effective;
        if (c) $('#motion-effective-settings').text('Active ' + (c.custom ? 'custom settings' : 'sensitivity preset') +
            ': start ' + c.trigger.toFixed(2) + '%, stop ' + c.release.toFixed(2) + '%, ' + c.confirm_samples +
            ' start samples, ' + c.quiet_ms + ' ms quiet time, ' + c.interval_ms + ' ms sampling; ' +
            (c.require_zero ? 'motion level must reach zero to stop.' : 'stopping uses the change ratio.'));
        var m = data.metrics;
        var mask = m && m.mask;
        maskActivity = mask && mask.error === 0 ? (mask.activity || '') : '';
        if (maskSupported) {
            $('#motion-mask-status').text(!mask || !mask.enabled ? 'Mask disabled.' : mask.error ?
                (mask.fallback ? 'Spatial data unavailable: using whole-view detection until the encoder map recovers.' : 'Waiting for a fresh encoder map; motion confirmation is paused.') :
                'Spatial score: ' + mask.ratio.toFixed(3) + '%, map age: ' + mask.age_ms + ' ms. Red cells are excluded after saving.');
            drawMask();
        }
        if (!m || m.read_error || m.bin_ratio === null) {
            $('#motion-live-readings').text(data.status === 'stopped' ? 'Enable motion detection to see live readings.' :
                'No recent detector sample' + (m && m.read_error ? ' (sampling error).' : '.'));
            $('#motion-history-chart').attr('hidden', 'hidden');
            return;
        }
        function raw(value) { return typeof value === 'number' ? value : 'unavailable'; }
        $('#motion-live-readings').text('BinImgRatio: ' + m.bin_ratio.toFixed(2) + '%, Scene: ' + raw(m.scene) +
            ', Move: ' + raw(m.move) + ', MovingLevel: ' + raw(m.moving_level) + ', MovingTh: ' + raw(m.moving_th) +
            '; detector: ' + (m.active ? 'motion' : 'idle') + ', quiet countdown: ' + m.quiet_elapsed_ms + '/' +
            m.effective.quiet_ms + ' ms, sample age: ' + m.sample_age_ms + ' ms.' +
            (mask && mask.enabled && !mask.error ? ' Spatial score (pink): ' + mask.ratio.toFixed(3) + '%.' : ''));
        if (m.monotonic_ms !== lastSampleTime) {
            motionSamples.push({time:m.monotonic_ms, bin_ratio:m.bin_ratio, scene:m.scene, move:m.move,
                moving_level:m.moving_level, moving_th:m.moving_th,
                masked_ratio:mask && mask.enabled && !mask.error ? mask.ratio : null});
            if (motionSamples.length > 60) motionSamples.shift();
            lastSampleTime = m.monotonic_ms;
        }
        var begin = m.monotonic_ms - 120000;
        motionSamples = motionSamples.filter(function(p) { return p.time >= begin; });
        function peak(key) {
            return Math.max.apply(null, [0].concat(motionSamples.map(function(p) {
                return typeof p[key] === 'number' ? p[key] : 0;
            })));
        }
        function path(key, vertical) {
            var previous = null;
            return motionSamples.map(function(p) {
                if (typeof p[key] !== 'number') { previous = null; return ''; }
                var command = previous && p.time - previous.time <= 5000 ? 'L' : 'M';
                previous = p;
                return command + ((p.time - begin) * 600 / 120000) + ' ' + vertical(p[key]);
            }).join(' ');
        }
        var ceiling = Math.min(100, Math.max(1, c.trigger, c.release, peak('bin_ratio'), peak('masked_ratio')) * 1.2);
        function y(value) { return 120 - Math.min(value / ceiling, 1) * 100; }
        $('#motion-chart-start').attr('d', 'M0 ' + y(c.trigger) + ' L600 ' + y(c.trigger));
        $('#motion-chart-stop').attr('d', 'M0 ' + y(c.release) + ' L600 ' + y(c.release));
        $('#motion-chart-ratio').attr('d', path('bin_ratio', y));
        $('#motion-chart-masked').attr('d', path('masked_ratio', y));
        $('#motion-chart-scale').text('BinImgRatio: 0\u2013' + ceiling.toFixed(2) + '%');
        var grades = Math.max(4, peak('scene'), peak('move'), peak('moving_level'));
        function gradeY(value) { return 250 - value * 80 / grades; }
        $('#motion-chart-scene').attr('d', path('scene', gradeY));
        $('#motion-chart-move').attr('d', path('move', gradeY));
        $('#motion-chart-level').attr('d', path('moving_level', gradeY));
        $('#motion-chart-grades-scale').text('Vendor grades: 0\u2013' + grades);
        var threshold = Math.max(31, peak('moving_th'));
        $('#motion-chart-threshold').attr('d', path('moving_th', function(value) { return 350 - value * 50 / threshold; }));
        $('#motion-chart-threshold-scale').text('MovingTh: 0\u2013' + threshold + ' (block difference threshold)');
        $('#motion-history-chart').removeAttr('hidden');
    }

    function renderIvaMetrics(data) {
        var mask = data.iva_mask;
        $('#motion-effective-settings').text('Native firmware sensitivity and timing are active.');
        if (!mask || !maskSupported) return;
        maskActivity = !mask.error ? (mask.activity || '') : '';
        $('#motion-mask-status').text(mask.error ?
            (mask.fallback ? 'Native mask unavailable: using whole-view detection.' : 'Waiting for the next processed native foreground sample.') :
            (mask.pending ? 'Mask update pending the next native sample. ' : '') +
            (mask.enabled ? 'Mask enabled. ' : 'Mask disabled. ') + 'Included foreground: ' + mask.ratio.toFixed(4) +
            '%, raw foreground: ' + mask.raw_ratio.toFixed(4) + '%, sample age: ' + mask.age_ms + ' ms.');
        drawMask();
        $('#motion-live-readings').text(mask.error ? 'No recent native foreground sample.' :
            'Native changed pixels: ' + mask.raw_count + '; included: ' + mask.included_count + '.');
        if (mask.error) { $('#motion-iva-chart').attr('hidden', 'hidden'); return; }
        if (mask.monotonic_ms !== lastSampleTime) {
            motionSamples.push({time:mask.monotonic_ms, raw:mask.raw_ratio, included:mask.ratio});
            if (motionSamples.length > 60) motionSamples.shift();
            lastSampleTime = mask.monotonic_ms;
        }
        var begin = mask.monotonic_ms - 120000;
        motionSamples = motionSamples.filter(function(p) { return p.time >= begin; });
        var ceiling = Math.max(0.1, Math.max.apply(null, motionSamples.map(function(p) { return p.raw; })) * 1.2);
        function path(key) {
            var previous = null;
            return motionSamples.map(function(p) {
                var command = previous && p.time - previous.time <= 5000 ? 'L' : 'M';
                previous = p;
                return command + ((p.time - begin) * 600 / 120000) + ' ' + (120 - p[key] * 110 / ceiling);
            }).join(' ');
        }
        $('#motion-iva-raw').attr('d', path('raw'));
        $('#motion-iva-included').attr('d', path('included'));
        $('#motion-iva-scale').text('Foreground: 0\u2013' + ceiling.toFixed(3) + '%; last 2 minutes.');
        $('#motion-iva-chart').removeAttr('hidden');
    }

    function updateNightvisionControls() {
        $('#NIGHTVISION_THRESHOLD').prop('disabled', $('#NIGHTVISION_MODE').prop('disabled') || $('#NIGHTVISION_MODE').val() !== 'auto');
    }

    function fetchNightvisionStatus() {
        $.ajax({
            type: "GET", url: 'cgi-bin/nightvision_status.sh', dataType: "json", cache: false,
            success: function(data) {
                $('#NIGHTVISION_MODE').prop('disabled', !data.supported);
                updateNightvisionControls();
                var message = data.supported ? 'Current mode: ' + data.state + (data.applied ? '' : ' (applying...)') : 'Night-vision controls unavailable on this firmware';
                if (data.supported && data.light_level >= 0) message += ', light level: ' + data.light_level;
                $('#nightvision-runtime-status').text(message);
            },
            error: function() { $('#nightvision-runtime-status').text('Night-vision status unavailable'); }
        });
    }

    function saveConfigs() {
        var saveStatusElem = $('#save-status');
        var configs = {};

        if (maskSupported) {
            if (!$('#MOTION_MASK_VECTOR_PIXELS')[0].checkValidity() || !$('#MOTION_MASK_DIFFERENCE')[0].checkValidity()) {
                saveStatusElem.text('Check the spatial block thresholds.'); return;
            }
            configs.MOTION_MASK_CELLS = maskCells;
            configs.MOTION_MASK_ENABLED = $('#MOTION_MASK_ENABLED').prop('checked') ? 'yes' : 'no';
            configs.MOTION_MASK_VECTOR_PIXELS = $('#MOTION_MASK_VECTOR_PIXELS').val();
            configs.MOTION_MASK_DIFFERENCE = $('#MOTION_MASK_DIFFERENCE').val();
        }

        if (customSupported && $('#MOTION_CUSTOM').prop('checked')) {
            var valid = true;
            $('#motion-custom-fields input[type="number"]').each(function() {
                if (!this.checkValidity()) valid = false;
            });
            if (!valid || Number($('#MOTION_STOP_THRESHOLD').val()) >= Number($('#MOTION_START_THRESHOLD').val())) {
                saveStatusElem.text('Check motion values: stop threshold must be below start, and all values must be within their shown ranges.');
                return;
            }
        }

        if (!$('#NIGHTVISION_THRESHOLD')[0].checkValidity()) {
            saveStatusElem.text("Night-vision threshold must be an integer from 1 to 100");
            return;
        }
        saveStatusElem.text("Saving...");

        $('.configs-switch input[type="checkbox"][data-key]').each(function() {
            if (!customSupported && /^MOTION_(CUSTOM|STOP_REQUIRE_ZERO)$/.test($(this).attr('data-key'))) return;
            if (!maskSupported && $(this).attr('data-key') === 'MOTION_MASK_ENABLED') return;
            configs[$(this).attr('data-key')] = $(this).prop('checked') ? 'yes' : 'no';
        });
        if (customSupported && $('#MOTION_CUSTOM').prop('checked')) {
            $('#motion-custom-fields input[type="number"]').each(function() {
                configs[$(this).attr('data-key')] = $(this).val();
            });
        }

        configs["MOTION_SENSITIVITY"] = $('select[data-key="MOTION_SENSITIVITY"]').prop('value');
        configs["SOUND_SENSITIVITY"] = $('select[data-key="SOUND_SENSITIVITY"]').prop('value');
        configs["CRUISE"] = $('select[data-key="CRUISE"]').prop('value');
        if (!$('#NIGHTVISION_MODE').prop('disabled')) {
            configs["NIGHTVISION_MODE"] = $('#NIGHTVISION_MODE').val();
            configs["NIGHTVISION_THRESHOLD"] = $('#NIGHTVISION_THRESHOLD').val();
        }

        $.ajax({
            type: "POST",
            url: 'cgi-bin/set_configs.sh?conf=camera',
            data: JSON.stringify(configs),
            dataType: "json",
            success: function(response) {
                if (response.error === true || response.error === "true") {
                    saveStatusElem.text(response.description || "Error while saving");
                    return;
                }
                var params = [
                    'switch_on=' + configs["SWITCH_ON"],
                    'sound_detection=' + configs["SOUND_DETECTION"],
                    'sound_sensitivity=' + configs["SOUND_SENSITIVITY"],
                    'led=' + configs["LED"],
                    'rotate=' + configs["ROTATE"],
                    'cruise=' + configs["CRUISE"]
                ];

                $.ajax({
                    type: "GET",
                    url: 'cgi-bin/camera_settings.sh?' + params.join('&'),
                    dataType: "json",
                    success: function(response) {
                        saveStatusElem.text(response.error === true || response.error === "true" ? (response.description || "Runtime apply failed") : "Saved");
                        fetchMotionStatus();
                        fetchNightvisionStatus();
                    },
                    error: function(response) {
                        saveStatusElem.text("Saved, but runtime apply failed");
                        fetchMotionStatus();
                        console.log('error', response);
                    }
                });
            },
            error: function(response) {
                saveStatusElem.text("Error while saving");
                console.log('error', response);
            }
        });
    }

    function updatePage() {
        $.ajax({
            type: "GET",
            url: 'cgi-bin/status.json',
            dataType: "json",
            success: function(data) {
                var ptz_enabled = ["r30gb", "r35gb", "r37gb", "r40ga", "h51ga", "h52ga", "h60ga", "q321br_lsx", "qg311r", "b091qp"];
                var this_model = data["model_suffix"] || "unknown";
                var lst = document.querySelectorAll(".ptz");
                for (var i = 0; i < lst.length; ++i) {
                    lst[i].style.display = ptz_enabled.includes(this_model) ? 'table-row' : 'none';
                }
            },
            error: function(response) {
                console.log('error', response);
            }
        });
    }

    return {
        init: init
    };

})(jQuery);
