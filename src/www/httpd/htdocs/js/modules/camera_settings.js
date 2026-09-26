var APP = APP || {};

APP.camera_settings = (function($) {

    var motionStatusTimer = null;

    function init() {
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

                $.each(response, function(key, state) {
                    if (key === "MOTION_SENSITIVITY" || key === "SOUND_SENSITIVITY" || key === "CRUISE") {
                        $('select[data-key="' + key + '"]').prop('value', state);
                    } else {
                        $('input[type="checkbox"][data-key="' + key + '"]').prop('checked', state === 'yes');
                    }
                });
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
            fetchMotionStatus();
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

                if (data.sensitivity_supported) {
                    $('#MOTION_SENSITIVITY').prop('disabled', false);
                    $('#motion-sensitivity-description').text('Sensitivity for the active local motion detector.');
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

    function saveConfigs() {
        var saveStatusElem = $('#save-status');
        var configs = {};

        saveStatusElem.text("Saving...");

        $('.configs-switch input[type="checkbox"][data-key]').each(function() {
            configs[$(this).attr('data-key')] = $(this).prop('checked') ? 'yes' : 'no';
        });

        configs["MOTION_SENSITIVITY"] = $('select[data-key="MOTION_SENSITIVITY"]').prop('value');
        configs["SOUND_SENSITIVITY"] = $('select[data-key="SOUND_SENSITIVITY"]').prop('value');
        configs["CRUISE"] = $('select[data-key="CRUISE"]').prop('value');

        $.ajax({
            type: "POST",
            url: 'cgi-bin/set_configs.sh?conf=camera',
            data: JSON.stringify(configs),
            dataType: "json",
            success: function(response) {
                var params = [
                    'switch_on=' + configs["SWITCH_ON"],
                    'save_video_on_motion=' + configs["SAVE_VIDEO_ON_MOTION"],
                    'motion_detection=' + configs["MOTION_DETECTION"],
                    'motion_sensitivity=' + configs["MOTION_SENSITIVITY"],
                    'sound_detection=' + configs["SOUND_DETECTION"],
                    'sound_sensitivity=' + configs["SOUND_SENSITIVITY"],
                    'led=' + configs["LED"],
                    'ir=' + configs["IR"],
                    'rotate=' + configs["ROTATE"],
                    'cruise=' + configs["CRUISE"]
                ];

                $.ajax({
                    type: "GET",
                    url: 'cgi-bin/camera_settings.sh?' + params.join('&'),
                    dataType: "json",
                    success: function(response) {
                        saveStatusElem.text("Saved");
                        fetchMotionStatus();
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
