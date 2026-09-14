from pathlib import Path


def replace(path, old, new, count=1):
    p=Path(path); s=p.read_text()
    if old not in s: raise SystemExit(f'missing in {path}: {old[:100]!r}')
    p.write_text(s.replace(old,new,count))

# service.sh: exact process-name counting so the invoking shell command is never counted.
for service in ['src/static/static/yi-hack/script/service.sh', '/tmp/yi150-motion/service.sh']:
    replace(service,
'''ps_program()
{
    PS_PROGRAM=$(ps | grep $1 | grep -v grep | grep -c ^)
    if [ $PS_PROGRAM -gt 0 ]; then
        echo "started"
    else
        echo "stopped"
    fi
}''',
'''mp4record_count()
{
    ps | awk '$5 == "./mp4record" || $5 == "/home/app/mp4record" { n++ } END { print n+0 }'
}

ps_program()
{
    PS_PROGRAM=$(ps | grep $1 | grep -v grep | grep -c ^)
    if [ $PS_PROGRAM -gt 0 ]; then
        echo "started"
    else
        echo "stopped"
    fi
}''')
    replace(service,
'''        MP4_COUNT=$(ps | grep mp4record | grep -v grep | grep -c '^')''',
'''        MP4_COUNT=$(mp4record_count)''')
    replace(service,
'''        if [ $(ps | grep mp4record | grep -v grep | grep -c '^') -gt 0 ]; then
            killall mp4record
        fi''',
'''        if [ $(mp4record_count) -gt 0 ]; then
            killall mp4record
        fi''', count=1)
    replace(service,
'''        if [ $(ps | grep mp4record | grep -v grep | grep -c '^') -gt 0 ]; then
            killall mp4record
        fi''',
'''        if [ $(mp4record_count) -gt 0 ]; then
            killall mp4record
        fi''', count=1)
    replace(service,
'''    elif [ "$NAME" == "mp4record" ]; then
        RES=$(ps_program mp4record)''',
'''    elif [ "$NAME" == "mp4record" ]; then
        if [ $(mp4record_count) -gt 0 ]; then RES="started"; else RES="stopped"; fi''')

# motion_service: exact executable field matching for both managed daemons.
path='src/static/static/yi-hack/script/motion_service.sh'
p=Path(path); s=p.read_text()
old='''process_count()
{
    ps | grep "$1" | grep -v grep | grep -c '^'
}'''
new='''process_count()
{
    case "$1" in
        mp4record)
            ps | awk '$5 == "./mp4record" || $5 == "/home/app/mp4record" { n++ } END { print n+0 }'
            ;;
        motiond)
            ps | awk '$5 == "/tmp/sd/yi-hack/bin/motiond" { n++ } END { print n+0 }'
            ;;
        *)
            echo 0
            ;;
    esac
}'''
if old not in s: raise SystemExit('missing process_count')
s=s.replace(old,new)
s=s.replace("process_count '/bin/motiond'", 'process_count motiond')
p.write_text(s)

print('exact singleton counting patched')
