var APP = APP || {};

APP.camera_settings = (function($) {

    var motionStatusTimer = null;
    var customSupported = false;
    var firmwareOptionsSet = false;
    var savedMotionSensitivity = '5';
    var motionSamples = [];
    var lastSampleTime = null;

    function init() {
        customSupported = false;
        firmwareOptionsSet = false;
        motionSamples = [];
        lastSampleTime = null;
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
                customSupported = data.custom_supported === true;
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
        if (!customSupported) return;
        var c = data.effective;
        if (c) $('#motion-effective-settings').text('Active ' + (c.custom ? 'custom settings' : 'sensitivity preset') +
            ': start ' + c.trigger.toFixed(2) + '%, stop ' + c.release.toFixed(2) + '%, ' + c.confirm_samples +
            ' start samples, ' + c.quiet_ms + ' ms quiet time, ' + c.interval_ms + ' ms sampling; ' +
            (c.require_zero ? 'motion level must reach zero to stop.' : 'stopping uses the change ratio.'));
        var m = data.metrics;
        if (!m || m.read_error || m.bin_ratio === null) {
            $('#motion-live-readings').text(data.status === 'stopped' ? 'Enable motion detection to see live readings.' :
                'No recent detector sample' + (m && m.read_error ? ' (sampling error).' : '.'));
            $('#motion-history-chart').attr('hidden', 'hidden');
            return;
        }
        $('#motion-live-readings').text('Scene change: ' + m.bin_ratio.toFixed(2) + '%, motion level: ' + m.moving_level +
            ', state: ' + (m.active ? 'motion' : 'idle') + ', quiet countdown: ' + m.quiet_elapsed_ms + '/' +
            m.effective.quiet_ms + ' ms, sample age: ' + m.sample_age_ms + ' ms.');
        if (m.monotonic_ms !== lastSampleTime) {
            motionSamples.push(m.bin_ratio);
            if (motionSamples.length > 60) motionSamples.shift();
            lastSampleTime = m.monotonic_ms;
        }
        var ceiling = Math.min(100, Math.max(1, c.trigger, c.release, Math.max.apply(null, motionSamples)) * 1.2);
        function y(value) { return 120 - Math.min(value / ceiling, 1) * 100; }
        $('#motion-chart-start').attr('d', 'M0 ' + y(c.trigger) + ' L600 ' + y(c.trigger));
        $('#motion-chart-stop').attr('d', 'M0 ' + y(c.release) + ' L600 ' + y(c.release));
        $('#motion-chart-ratio').attr('d', motionSamples.map(function(value, i) {
            return (i ? 'L' : 'M') + (i * 600 / 59) + ' ' + y(value);
        }).join(' '));
        $('#motion-chart-scale').text('0\u2013' + ceiling.toFixed(2) + '%');
        $('#motion-history-chart').removeAttr('hidden');
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
