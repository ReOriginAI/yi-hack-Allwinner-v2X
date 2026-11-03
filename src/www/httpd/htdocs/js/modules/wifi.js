var APP = APP || {};

APP.wifi = (function($) {
    var currentPrimarySSID = "";
    var maintenancePasswordSet = false;

    function init() {
        $('#input-container').hide();
        registerEventHandler();
        updateWiFiPage();
    }

    function registerEventHandler() {
        $(document).on("click", '#button-save-wifi', function(e) {
            saveWiFi();
        });
        $(document).on("click", '#button-hotspot-start', function() { requestHotspot("start"); });
        $(document).on("click", '#button-hotspot-stop', function() { requestHotspot("stop"); });
        $(document).on("change", '#WIFI_ESSID', function(e) {
            toggleESSIDInput();
        });
    }

    function requestHotspot(action) {
        var status = $('#hotspot-request-status');
        status.text("Sending request...");
        $.ajax({type: "POST", url: "cgi-bin/wifi.sh?action=hotspot_" + action, dataType: "json",
            success: function(data) {
                status.text(data.error == "false" ?
                    (action == "start" ? "Request queued. Connect to the hotspot when this connection drops." :
                        "Request queued. Reconnect through your primary WiFi network.") :
                    "Not started: " + (data.message || "request failed"));
            },
            error: function() { status.text("Request failed. Check the camera connection."); }
        });
    }

    function selectedPrimarySSID() {
        if ($('select[data-key="WIFI_ESSID"]').prop('value') == "Other...") {
            return $('input[type="text"][data-key="WIFI_ESSID_MANUAL"]').prop('value');
        }
        return $('select[data-key="WIFI_ESSID"]').prop('value');
    }

    function saveWiFi() {
        var saveStatusElem = $('#save-wifi-status');
        var configs = {};
        var primarySSID = selectedPrimarySSID();
        var primaryPassword = $('#WIFI_PASSWORD').prop('value');
        var primaryPassword2 = $('#WIFI_PASSWORD2').prop('value');
        var maintenanceEnabled = $('#WIFI_MAINTENANCE_ENABLED').prop('checked');
        var maintenanceSSID = $('#WIFI_MAINTENANCE_SSID').prop('value');
        var maintenancePassword = $('#WIFI_MAINTENANCE_PASSWORD').prop('value');
        var maintenancePassword2 = $('#WIFI_MAINTENANCE_PASSWORD2').prop('value');
        var maintenanceGrace = $('#WIFI_MAINTENANCE_GRACE').prop('value');

        saveStatusElem.text("Saving...");

        if (!primarySSID && primaryPassword) {
            saveStatusElem.text("Not saved, primary SSID is blank.");
            return;
        }
        if (primaryPassword && primaryPassword != primaryPassword2) {
            saveStatusElem.text("Not saved, primary passwords don't match.");
            return;
        }
        if (primaryPassword.length > 63) {
            saveStatusElem.text("Not saved, primary password is too long.");
            return;
        }
        if (primarySSID && primarySSID != currentPrimarySSID && !primaryPassword) {
            saveStatusElem.text("Not saved, enter the primary password when changing SSID.");
            return;
        }

        if (maintenanceEnabled) {
            if (!maintenanceSSID) {
                saveStatusElem.text("Not saved, maintenance SSID is blank.");
                return;
            }
            if (maintenanceSSID.length > 32) {
                saveStatusElem.text("Not saved, maintenance SSID is too long.");
                return;
            }
            if (!maintenancePassword && !maintenancePasswordSet) {
                saveStatusElem.text("Not saved, maintenance password is required.");
                return;
            }
        }

        if (maintenancePassword) {
            if (maintenancePassword.length < 8 || maintenancePassword.length > 63) {
                saveStatusElem.text("Not saved, maintenance password must be 8-63 characters.");
                return;
            }
            if (maintenancePassword != maintenancePassword2) {
                saveStatusElem.text("Not saved, maintenance passwords don't match.");
                return;
            }
        }

        var grace = parseInt(maintenanceGrace, 10);
        if (isNaN(grace) || grace < 30 || grace > 3600) {
            saveStatusElem.text("Not saved, grace period must be 30-3600 seconds.");
            return;
        }

        if (primarySSID && (primaryPassword || primarySSID != currentPrimarySSID)) {
            configs["WIFI_ESSID"] = primarySSID;
            configs["WIFI_PASSWORD"] = primaryPassword;
            configs["WIFI_PASSWORD2"] = primaryPassword2;
        }

        var hotspotChannel = Number($('#WIFI_HOTSPOT_CHANNEL').val());
        if (!Number.isInteger(hotspotChannel) || hotspotChannel < 1 || hotspotChannel > 11) {
            saveStatusElem.text("Not saved, hotspot channel must be 1-11.");
            return;
        }
        configs["WIFI_HOTSPOT_BOOT"] = $('#WIFI_HOTSPOT_BOOT').prop('checked') ? "yes" : "no";
        configs["WIFI_HOTSPOT_SSID"] = $('#WIFI_HOTSPOT_SSID').val();
        configs["WIFI_HOTSPOT_CHANNEL"] = String(hotspotChannel);
        var hotspotPassword = $('#WIFI_HOTSPOT_PASSWORD').val();
        var clearHotspotPassword = $('#WIFI_HOTSPOT_CLEAR_PASSWORD').prop('checked');
        if (hotspotPassword && (!/^[ -~]{8,63}$/.test(hotspotPassword) || clearHotspotPassword)) {
            saveStatusElem.text("Not saved, use 8-63 printable ASCII characters or choose to remove the password.");
            return;
        }
        configs["WIFI_HOTSPOT_PASSWORD"] = hotspotPassword;
        configs["WIFI_HOTSPOT_CLEAR_PASSWORD"] = clearHotspotPassword ? "yes" : "no";
        configs["WIFI_RESET_HOTSPOT"] = $('#WIFI_RESET_HOTSPOT').prop('checked') ? "yes" : "no";
        configs["WIFI_MAINTENANCE_ENABLED"] = maintenanceEnabled ? "yes" : "no";
        configs["WIFI_MAINTENANCE_SSID"] = maintenanceSSID;
        configs["WIFI_MAINTENANCE_GRACE"] = String(grace);

        if (maintenancePassword) {
            configs["WIFI_MAINTENANCE_PASSWORD"] = maintenancePassword;
            configs["WIFI_MAINTENANCE_PASSWORD2"] = maintenancePassword2;
        }

        $.ajax({
            type: "POST",
            url: 'cgi-bin/wifi.sh?action=save',
            data: JSON.stringify(configs),
            dataType: "json",
            success: function(response) {
                if (!response || response.error != "false") {
                    saveStatusElem.text("Not saved: " + ((response && response.message) ? response.message : "generic error."));
                } else {
                    saveStatusElem.text("Saved. Reboot the camera to apply WiFi changes.");
                    $('#WIFI_HOTSPOT_PASSWORD').val('');
                    $('#WIFI_HOTSPOT_CLEAR_PASSWORD').prop('checked', false);
                    currentPrimarySSID = primarySSID;
                    if (maintenancePassword) {
                        maintenancePasswordSet = true;
                        $('#WIFI_MAINTENANCE_PASSWORD').prop('value', '');
                        $('#WIFI_MAINTENANCE_PASSWORD2').prop('value', '');
                    }
                    $('#WIFI_PASSWORD').prop('value', '');
                    $('#WIFI_PASSWORD2').prop('value', '');
                }
            },
            error: function(response) {
                saveStatusElem.text("Error while saving");
                console.log('error', response);
            }
        });
    }

    function updateWiFiPage() {
        var loadingStatusElem = $('#loading-wifi-status');
        loadingStatusElem.text("Loading...");

        $.ajax({
            type: "GET",
            url: 'cgi-bin/wifi.sh?action=status',
            dataType: "json",
            success: function(data) {
                loadingStatusElem.fadeOut(500);
                $('#hotspot-state').text(data.hotspot_state || "station");
                $('#hotspot-name').text(data.hotspot_ssid || "the camera hotspot");
                $('#WIFI_HOTSPOT_SSID').val(data.hotspot_configured_ssid || "").attr('placeholder', data.hotspot_ssid || "Automatic");
                $('#WIFI_HOTSPOT_CHANNEL').val(data.hotspot_channel || "6");
                $('#WIFI_HOTSPOT_BOOT').prop('checked', data.hotspot_boot == "yes");
                $('#hotspot-password-description').text(data.hotspot_password_set ?
                    'A password is saved. Leave blank to keep it, or choose Remove hotspot password.' :
                    'No password is saved: the hotspot is open. Set 8-63 printable ASCII characters to protect it.');
                $('#reset-hotspot-current').text(data.reset_hotspot_armed ? 'Hotspot override active: hold five seconds.' : 'Factory reset. An enabled hotspot override takes effect after reboot.');
                $('#WIFI_RESET_HOTSPOT').prop('checked', data.reset_hotspot_supported && data.reset_hotspot == "yes").prop('disabled', !data.reset_hotspot_supported);
                if (!data.reset_hotspot_supported) {
                    $('#reset-hotspot-description').text("The reset button override is unavailable for this firmware. Hotspot controls remain available above.");
                }
                currentPrimarySSID = data.current_ssid || "";
                maintenancePasswordSet = !!data.maintenance_password_set;

                var networks = data.wifi || [];
                if (currentPrimarySSID && networks.indexOf(currentPrimarySSID ) < 0) {
                    networks.unshift(currentPrimarySSID);
                }

                var html = '<select data-key="WIFI_ESSID" id="WIFI_ESSID">';
                for (var i = 0; i < networks.length; i++) {
                    if (networks[i].length > 0) {
                        var selected = (networks[i] == currentPrimarySSID) ? ' selected' : '';
                        html += '<option value="' + $('<div/>').text(networks[i]).html() + '"' + selected + '>' +
                            $('<div/>').text(networks[i]).html() + '</option>';
                    }
                }
                html += '<option value="Other...">Other...</option>';
                html += '</select>';
                document.getElementById("select-container").innerHTML = html;

                $('#WIFI_MAINTENANCE_ENABLED').prop('checked', data.maintenance_enabled == "yes");
                $('#WIFI_MAINTENANCE_SSID').prop('value', data.maintenance_ssid || "");
                $('#WIFI_MAINTENANCE_GRACE').prop('value', data.maintenance_grace || "180");

                if (maintenancePasswordSet) {
                    $('#WIFI_MAINTENANCE_PASSWORD').attr('placeholder', 'Leave blank to keep current password');
                    $('#WIFI_MAINTENANCE_PASSWORD2').attr('placeholder', 'Leave blank to keep current password');
                }

                $('#WIFI_PASSWORD').attr('placeholder', 'Leave blank to keep current primary password');
                $('#WIFI_PASSWORD2').attr('placeholder', 'Leave blank to keep current primary password');
                toggleESSIDInput();
            },
            error: function(response) {
                loadingStatusElem.text("Error loading WiFi configuration");
                console.log('error', response);
            }
        });
    }

    function toggleESSIDInput() {
        if ($("#WIFI_ESSID option:selected").text() == "Other...") {
            $('#input-container').show();
        } else {
            $('#input-container').hide();
        }
    }

    return {
        init: init
    };

})(jQuery);
