var APP = APP || {};

APP.maintenance = (function($) {

    var timeoutVar;

    function init() {
        registerEventHandler();
        setRebootStatus("Camera is online.");
        getFwStatus();
    }

    function registerEventHandler() {
        $(document).on("click", '#button-save', function(e) {
            saveConfig();
        });
        $(document).on("click", '#button-load', function(e) {
            loadConfig();
        });
        $(document).on("click", '#button-reboot', function(e) {
            rebootCamera();
        });
        $(document).on("click", '#button-reset', function(e) {
            resetCamera();
        });
        $(document).on("click", '#button-upgrade', function(e) {
            upgradeFirmware();
        });
        $(document).on("click", '#button-fw-upload', function(e) {
            uploadFirmware();
        });
    }

    function saveConfig() {
        $('#button-save').attr("disabled", true);
        var xhr = new XMLHttpRequest();
        xhr.open('GET', 'cgi-bin/save.sh', true);
        xhr.responseType = 'blob';
        xhr.onload = function(e) {
            if (xhr.status == 200) {
                var myBlob = xhr.response;
                var url = URL.createObjectURL(myBlob);
                var $a = $('<a />', {
                    'href': url,
                    'download': 'config.tar.bz2',
                    'text': "click"
                }).hide().appendTo("body")[0].click();
                URL.revokeObjectURL(url);
            }
            $('#button-save').attr("disabled", false);
        };
        xhr.onerror = function() {
            $('#button-save').attr("disabled", false);
        };
        xhr.send();
    }

    function loadConfig() {
        $('#button-load').attr("disabled", true);
        var fileSelect = document.getElementById('button-file');
        var files = fileSelect.files;
        var formData = new FormData();

        for (var i = 0; i < files.length; i++) {
            var file = files[i];
            formData.append('files[]', file, file.name);
        }

        var xhr = new XMLHttpRequest();
        xhr.open('POST', 'cgi-bin/load.sh', true);
        xhr.onload = function() {
            $('#button-load').attr("disabled", false);
            var myText = xhr.response;
            $('#text-load').text(myText);
        };
        xhr.onerror = function() {
            $('#button-load').attr("disabled", false);
            $('#text-load').text("Upload failed.");
        };
        xhr.send(formData);
    }

    function rebootCamera() {
        var confirmation = confirm("Are you sure you want to reboot?");
        if (confirmation) {
            $('#button-reboot').attr("disabled", true);
            $.ajax({
                type: "GET",
                url: 'cgi-bin/reboot.sh',
                dataType: "json",
                error: function(response) {
                    console.log('error', response);
                    $('#button-reboot').attr("disabled", false);
                },
                success: function(data) {
                    setRebootStatus("Camera is rebooting.");
                    waitForBoot();
                },
                complete: function() {
                    $('#button-reboot').attr("disabled", false);
                }
            });
        }
    }

    function waitForBoot() {
        setInterval(function() {
            $.ajax({
                url: 'index.html',
                cache: false,
                success: function(data) {
                    setRebootStatus("Camera is back online, redirecting to home.");
                    $('#button-reboot').attr("disabled", false);
                    window.location.href = "index.html";
                },
                error: function(data) {
                    setRebootStatus("Waiting for the camera to come back online.");
                },
                timeout: 3000,
            });
        }, 5000);
    }

    function resetCamera() {
        var confirmation = confirm("Are you sure you want to reset?");
        if (confirmation) {
            $('#button-reset').attr("disabled", true);
            $.ajax({
                type: "GET",
                url: 'cgi-bin/reset.sh',
                dataType: "json",
                error: function(response) {
                    console.log('error', response);
                },
                success: function(data) {
                    setResetStatus("Reset completed, reboot your camera.");
                },
                complete: function() {
                    $('#button-reset').attr("disabled", false);
                }
            });
        }
    }

    function setUpgradeControlsDisabled(disabled) {
        $('#button-upgrade').attr("disabled", disabled);
        $('#button-fw-upload').attr("disabled", disabled);
        $('#button-fw-file').attr("disabled", disabled);
    }

    function uploadFirmware() {
        var fileSelect = document.getElementById('button-fw-file');
        var file = fileSelect && fileSelect.files ? fileSelect.files[0] : null;

        if (!file) {
            $('#text-fw-upload').text("Select a firmware .tgz first.");
            return;
        }
        if (!/\.tgz$/i.test(file.name)) {
            $('#text-fw-upload').text("Only .tgz firmware packages are supported.");
            return;
        }
        if (file.size <= 0 || file.size > 67108864) {
            $('#text-fw-upload').text("Firmware must be between 1 byte and 64 MiB.");
            return;
        }

        var confirmation = confirm(
            "Upload " + file.name + " and start the firmware upgrade? " +
            "The camera will reboot and may reboot more than once. Do not remove power or the SD card."
        );
        if (!confirmation) {
            return;
        }

        setUpgradeControlsDisabled(true);
        $('#text-fw-upload').text("Uploading 0%...");
        setFwStatus("Firmware upload in progress.");

        var xhr = new XMLHttpRequest();
        xhr.open('POST', 'cgi-bin/fw_upload.sh', true);
        xhr.setRequestHeader('Content-Type', 'application/gzip');

        xhr.upload.onprogress = function(e) {
            if (e.lengthComputable && e.total > 0) {
                var percent = Math.min(100, Math.round((e.loaded * 100) / e.total));
                $('#text-fw-upload').text("Uploading " + percent + "%...");
            }
        };

        xhr.onload = function() {
            var data;
            try {
                data = JSON.parse(xhr.responseText);
            } catch (e) {
                data = { error: true, description: "Invalid response from camera." };
            }

            if (xhr.status !== 200 || data.error) {
                var message = data.description || "Firmware upload failed.";
                $('#text-fw-upload').text(message);
                setFwStatus(message);
                setUpgradeControlsDisabled(false);
                return;
            }

            var staged = "Validated " + data.model + " firmware " + data.version + ".";
            $('#text-fw-upload').text(staged + " Starting upgrade...");
            setFwStatus(staged + " Preparing upgrade.");
            runFirmwareUpgrade();
        };

        xhr.onerror = function() {
            $('#text-fw-upload').text("Firmware upload failed.");
            setFwStatus("Firmware upload failed.");
            setUpgradeControlsDisabled(false);
        };

        xhr.send(file);
    }

    function upgradeFirmware() {
        setFwStatus("Firmware download in progress.");
        runFirmwareUpgrade();
    }

    function runFirmwareUpgrade() {
        setUpgradeControlsDisabled(true);
        $.ajax({
            type: "GET",
            url: 'cgi-bin/fw_upgrade.sh?get=upgrade',
            error: function(response) {
                console.log('error', response);
                setFwStatus("Unable to start firmware upgrade.");
                setUpgradeControlsDisabled(false);
            },
            success: function(response) {
                setFwStatus(response);
                if (response.indexOf("rebooting") !== -1 || response.indexOf("upgrading") !== -1) {
                    waitForUpgrade();
                } else {
                    setUpgradeControlsDisabled(false);
                }
            }
        });
    }

    function waitForUpgrade() {
        var sawOffline = false;
        var onlineSuccesses = 0;

        if (timeoutVar) {
            clearInterval(timeoutVar);
        }

        timeoutVar = setInterval(function() {
            $.ajax({
                url: 'index.html',
                cache: false,
                success: function(data) {
                    if (!sawOffline) {
                        setFwStatus("Upgrade staged; waiting for reboot...");
                        return;
                    }

                    onlineSuccesses++;
                    if (onlineSuccesses < 2) {
                        setFwStatus("Camera is coming back online...");
                        return;
                    }

                    clearInterval(timeoutVar);
                    timeoutVar = null;
                    setFwStatus("Firmware upgrade completed; redirecting to home.");
                    setUpgradeControlsDisabled(false);
                    window.location.href = "index.html";
                },
                error: function(data) {
                    sawOffline = true;
                    onlineSuccesses = 0;
                    setFwStatus("Firmware upgrade in progress; waiting for camera...");
                },
                timeout: 3000,
            });
        }, 5000);
    }

    function setRebootStatus(text) {
        $('input[type="text"][data-key="STATUS"]').prop('value', text);
    }

    function setResetStatus(text) {
        $('input[type="text"][data-key="RESET"]').prop('value', text);
    }

    function setFwStatus(text) {
        $('input[type="text"][data-key="FW"]').prop('value', text);
    }

    function getFwStatus() {
        $.ajax({
            type: "GET",
            url: 'cgi-bin/fw_upgrade.sh?get=info',
            dataType: "json",
            error: function(response) {
                console.log('error', response);
                setFwStatus("Error getting fw info");
            },
            success: function(data) {
                if (data.local_fw) {
                    setFwStatus("Installed: " + data.fw_version + " - Available: local SD");
                } else {
                    setFwStatus("Installed: " + data.fw_version + " - Available: " + data.latest_fw);
                }
                if ((data.fw_version == data.latest_fw) && (!data.local_fw)) {
                    $('#button-upgrade').attr("disabled", true);
                }
            }
        });
    }

    return {
        init: init
    };

})(jQuery);
