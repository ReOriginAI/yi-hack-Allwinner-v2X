var APP = APP || {};

APP.audio = (function($) {

    function init() {
        registerEventHandler();
        loadFiles();
    }

    function registerEventHandler() {
        $(document).off(".audioModule");
        $(document).on("submit.audioModule", '#tts-form', function(e) {
            e.preventDefault();
            speakText();
        });

        $(document).on("click.audioModule", '#audio-library-upload', function(e) {
            uploadFile();
        });

        $(document).on("click.audioModule", '#audio-library-refresh', function(e) {
            loadFiles();
        });

        $(document).on("click.audioModule", '.audio-library-play', function(e) {
            var file = $(this).attr('data-file');
            var volume = $(this).closest('tr').find('.audio-library-volume').prop('value');
            playFile(file, volume);
        });

        $(document).on("click.audioModule", '.audio-library-delete', function(e) {
            var file = $(this).attr('data-file');
            deleteFile(file);
        });
    }

    function setStatus(text) {
        $('#audio-library-status').text(text || '');
    }

    function setTtsStatus(text) {
        $('#tts-status').text(text || '');
    }

    function responseDescription(xhr, fallback) {
        if (xhr && xhr.responseJSON && xhr.responseJSON.description) {
            return xhr.responseJSON.description;
        }
        return fallback;
    }

    function validNumber(value, min, max) {
        var n = parseFloat(value);
        return isFinite(n) && n >= min && n <= max;
    }

    function speakText() {
        var text = $('#tts-text').prop('value') || '';
        var voice = $('#tts-voice').prop('value') || 'en-US';
        var speed = $('#tts-speed').prop('value') || '1.0';
        var pitch = $('#tts-pitch').prop('value') || '1.0';
        var volume = $('#tts-volume').prop('value') || '1.0';

        if (!text.trim()) {
            setTtsStatus('Enter some text first.');
            return;
        }
        if (text.length > 1024) {
            setTtsStatus('Text is too long.');
            return;
        }
        if (!validNumber(speed, 0.2, 5.0) || !validNumber(pitch, 0.5, 2.0) || !validNumber(volume, 0.0, 5.0)) {
            setTtsStatus('Speed, pitch, or volume is outside the supported range.');
            return;
        }

        $('#tts-speak').attr('disabled', true);
        setTtsStatus('Speaking...');

        $.ajax({
            url: 'cgi-bin/tts.sh?voice=' + encodeURIComponent(voice) +
                '&speed=' + encodeURIComponent(speed) +
                '&pitch=' + encodeURIComponent(pitch) +
                '&volume=' + encodeURIComponent(volume),
            type: 'POST',
            contentType: 'text/plain; charset=UTF-8',
            processData: false,
            dataType: 'json',
            data: text,
            success: function(data) {
                if (data.error) {
                    setTtsStatus(data.description || 'Text-to-speech failed.');
                } else {
                    setTtsStatus('Finished speaking.');
                }
            },
            error: function(xhr) {
                setTtsStatus(responseDescription(xhr, 'Text-to-speech failed.'));
            },
            complete: function() {
                $('#tts-speak').attr('disabled', false);
            }
        });
    }

    function formatBytes(bytes) {
        var value = parseInt(bytes, 10) || 0;
        if (value < 1024) return value + ' B';
        if (value < 1024 * 1024) return (value / 1024).toFixed(1) + ' KiB';
        return (value / (1024 * 1024)).toFixed(1) + ' MiB';
    }

    function buildVolumeSelect() {
        var values = [12, 10, 8, 6, 4, 2, 0, -2, -4, -6, -8, -10, -12];
        var select = $('<select />', {'class': 'audio-library-volume'});
        for (var i = 0; i < values.length; i++) {
            var value = values[i];
            var label = value > 0 ? '+' + value + 'dB' : value + 'dB';
            var option = $('<option />', {'value': value}).text(label);
            if (value === 0) option.prop('selected', true);
            select.append(option);
        }
        return $('<div />', {'class': 'standard-select'}).append(select);
    }

    function renderFiles(files) {
        var list = $('#audio-library-list');
        list.empty();

        if (!files || files.length === 0) {
            list.append($('<tr />').append($('<td />', {'colspan': 4}).text('No stored audio files.')));
            return;
        }

        files.sort(function(a, b) {
            return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
        });

        for (var i = 0; i < files.length; i++) {
            var file = files[i];
            var row = $('<tr />');
            var play = $('<input />', {
                'class': 'button-primary audio-library-play',
                'type': 'button',
                'value': 'Play',
                'data-file': file.name
            });
            var remove = $('<input />', {
                'class': 'audio-library-delete',
                'type': 'button',
                'value': 'Delete',
                'data-file': file.name
            });

            row.append($('<td />').text(file.name));
            row.append($('<td />').text(formatBytes(file.size)));
            row.append($('<td />').append(buildVolumeSelect()));
            row.append($('<td />').append(play).append(' ').append(remove));
            list.append(row);
        }
    }

    function loadFiles() {
        setStatus('Loading audio library...');
        $.ajax({
            url: 'cgi-bin/audio_library.sh?action=list',
            type: 'GET',
            dataType: 'json',
            cache: false,
            success: function(data) {
                if (data.error) {
                    setStatus(data.description || 'Unable to list audio files.');
                    return;
                }
                renderFiles(data.files);
                setStatus('');
            },
            error: function(xhr) {
                setStatus(responseDescription(xhr, 'Unable to load audio library.'));
            }
        });
    }

    function uploadFile() {
        var file = $('#audio-library-file').prop('files')[0];
        if (!file) {
            setStatus('Choose a .pcm or .wav file first.');
            return;
        }

        var formData = new FormData();
        formData.append('file', file, file.name);

        $('#audio-library-upload').attr('disabled', true);
        setStatus('Uploading ' + file.name + '...');

        $.ajax({
            url: 'cgi-bin/audio_library.sh?action=upload',
            type: 'POST',
            contentType: false,
            processData: false,
            dataType: 'json',
            data: formData,
            cache: false,
            success: function(data) {
                if (data.error) {
                    setStatus(data.description || 'Upload failed.');
                    return;
                }
                $('#audio-library-file').prop('value', '');
                setStatus('Uploaded ' + data.name + '.');
                loadFiles();
            },
            error: function(xhr) {
                setStatus(responseDescription(xhr, 'Upload failed.'));
            },
            complete: function() {
                $('#audio-library-upload').attr('disabled', false);
            }
        });
    }

    function playFile(file, volume) {
        $('.audio-library-play').attr('disabled', true);
        setStatus('Playing ' + file + '...');

        $.ajax({
            url: 'cgi-bin/audio_library.sh?action=play&voldb=' + encodeURIComponent(volume),
            type: 'POST',
            contentType: 'text/plain; charset=UTF-8',
            processData: false,
            dataType: 'json',
            data: file,
            success: function(data) {
                if (data.error) {
                    setStatus(data.description || 'Playback failed.');
                } else {
                    setStatus('Finished ' + file + '.');
                }
            },
            error: function(xhr) {
                setStatus(responseDescription(xhr, 'Playback failed.'));
            },
            complete: function() {
                $('.audio-library-play').attr('disabled', false);
            }
        });
    }

    function deleteFile(file) {
        if (!confirm('Delete ' + file + '?')) return;

        setStatus('Deleting ' + file + '...');
        $.ajax({
            url: 'cgi-bin/audio_library.sh?action=delete',
            type: 'POST',
            contentType: 'text/plain; charset=UTF-8',
            processData: false,
            dataType: 'json',
            data: file,
            success: function(data) {
                if (data.error) {
                    setStatus(data.description || 'Delete failed.');
                } else {
                    setStatus('Deleted ' + file + '.');
                    loadFiles();
                }
            },
            error: function(xhr) {
                setStatus(responseDescription(xhr, 'Delete failed.'));
            }
        });
    }

    return {
        init: init
    };

})(jQuery);
