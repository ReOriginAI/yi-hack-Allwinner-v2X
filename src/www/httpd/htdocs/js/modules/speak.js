var APP = APP || {};

APP.speak = (function($) {

    function init() {
        registerEventHandler();
    }

    function registerEventHandler() {
        $(document).on("click", '#button-speak', function(e) {
            sendText();
        });
        $(document).on("click", '#button-speaker', function(e) {
            sendWav();
        });
    }

    function setTtsStatus(message, isError) {
        var status = $('#tts-status');
        if (!status.length) {
            status = $('<span id="tts-status" style="margin-left: 1em;"></span>');
            $('#button-speak').after(status);
        }
        status.text(message || '');
        status.css('font-weight', isError ? 'bold' : 'normal');
    }

    function sendText() {
        var ttsterm = $("input[name='ttsinput']").prop('value') || '';
        var ttslang = $("select[name='ttslang']").prop('value') || 'en-US';
        var ttsvolDb = parseFloat($("select[name='ttsvol']").prop('value') || '0');
        var ttsvolume;

        if (!ttsterm.trim()) {
            setTtsStatus('Enter text to speak.', true);
            return;
        }

        // The legacy UI expresses gain in dB, while the NanoTTS endpoint takes
        // a linear 0.0-5.0 volume multiplier.
        ttsvolume = Math.pow(10, ttsvolDb / 20);
        ttsvolume = Math.max(0, Math.min(5, ttsvolume));

        setTtsStatus('Speaking...', false);
        $('#button-speak').prop('disabled', true);

        $.ajax({
            url: "cgi-bin/tts.sh?voice=" + encodeURIComponent(ttslang) +
                 "&speed=1.0&pitch=1.0&volume=" + ttsvolume.toFixed(3),
            type: 'POST',
            contentType: 'text/plain; charset=UTF-8',
            dataType: 'json',
            data: ttsterm,
            cache: false,
            processData: false
        }).done(function(response) {
            if (response && response.error) {
                setTtsStatus(response.description || 'TTS failed.', true);
            } else {
                setTtsStatus('Spoken.', false);
            }
        }).fail(function(xhr) {
            var message = 'TTS request failed.';
            if (xhr.responseJSON && xhr.responseJSON.description) {
                message = xhr.responseJSON.description;
            }
            setTtsStatus(message, true);
        }).always(function() {
            $('#button-speak').prop('disabled', false);
        });
    }

    function sendWav() {
        var fileData = $('#wavfile').prop('files')[0];
        var formData;
        var wavvol;

        if (!fileData) {
            return;
        }

        formData = new FormData();
        formData.append('file', fileData);
        wavvol = $("select[name='wavvol']").prop('value');
        $.ajax({
            url: "cgi-bin/speaker.sh?voldb=" + wavvol,
            type: 'POST',
            contentType: false,
            data: formData,
            cache: false,
            processData: false
        });
    }

    return {
        init: init
    };

})(jQuery);
