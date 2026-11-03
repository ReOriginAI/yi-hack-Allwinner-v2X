var APP = APP || {};
APP.clock = (function($) {
    function showClock(data) {
        $('#clock-current').text(data.utc || 'Unavailable');
        if (data.ntp_enabled === false) {
            $('input[data-key="NTPD"]').prop('checked', false);
        }
    }
    function setClock(epoch) {
        if (!isFinite(epoch)) {
            $('#clock-status').text('Enter a valid date and time.');
            return;
        }
        $('#clock-status').text('Setting clock...');
        $('.clock-action').prop('disabled', true);
        $.ajax({
            type: 'POST', url: 'cgi-bin/clock.sh', dataType: 'json',
            contentType: 'application/json', data: JSON.stringify({epoch: epoch}),
            success: function(data) {
                if (data.error) {
                    $('#clock-status').text(data.message || 'Could not set clock.');
                } else {
                    showClock(data);
                    $('#clock-status').text('Clock set. Automatic NTP sync is disabled.');
                }
            },
            error: function() { $('#clock-status').text('Could not reach the camera.'); },
            complete: function() { $('.clock-action').prop('disabled', false); }
        });
    }
    function init() {
        var now = new Date();
        $('#clock-manual').val(new Date(now.getTime() - now.getTimezoneOffset() * 60000).toISOString().slice(0, 19));
        $(document).off('click.clock', '#clock-browser').on('click.clock', '#clock-browser', function() {
            setClock(Math.floor(Date.now() / 1000));
        });
        $(document).off('click.clock', '#clock-set').on('click.clock', '#clock-set', function() {
            var value = $('#clock-manual').val();
            setClock(value ? Math.floor(new Date(value).getTime() / 1000) : NaN);
        });
        $.getJSON('cgi-bin/clock.sh', showClock).fail(function() {
            $('#clock-current').text('Unavailable');
        });
    }
    return {init: init};
})(jQuery);
