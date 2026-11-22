"""Build pinned export-only iOS libraries; never execute media or tests."""
import argparse, json, os, pathlib, subprocess, tarfile
ROOT = pathlib.Path(__file__).resolve().parents[3]
PACKAGE = ROOT / "Packages/MediaExportNative"
WORK = ROOT / "build/export-media"
SOURCES = WORK / "sources"
PINS = json.loads((PACKAGE / "Configuration/sources.json").read_text())
DEVELOPER = pathlib.Path('/Applications/Xcode.app/Contents/Developer')
BIN = DEVELOPER / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'

def run(args, cwd=None, env=None):
    print(' '.join(map(str,args)),flush=True)
    subprocess.run(list(map(str,args)),cwd=cwd,env=env,check=True)

def extract():
    for name,pin in PINS.items():
        dest=SOURCES/name
        if dest.exists(): continue
        archive=SOURCES/(name+'.tar.gz')
        with tarfile.open(archive) as tar:
            top=tar.getmembers()[0].name.split('/')[0]
            tar.extractall(SOURCES,filter='data')
        (SOURCES/top).rename(dest)
    import shutil
    shutil.copytree(SOURCES/'fast-float',SOURCES/'libplacebo/3rdparty/fast_float',dirs_exist_ok=True)
    # All source directories are generated archive inputs, not user checkouts.

def build(arch,sdk):
    sysroot=DEVELOPER/'Platforms'/('iPhoneOS.platform' if sdk=='iphoneos' else 'iPhoneSimulator.platform')/'Developer/SDKs'/('iPhoneOS.sdk' if sdk=='iphoneos' else 'iPhoneSimulator.sdk')
    triple=f'{arch}-apple-ios18.0'+('' if sdk=='iphoneos' else '-simulator')
    folder=WORK/(sdk+'-'+arch); prefix=folder/'prefix'; prefix.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy();env['PATH']=str(WORK/'venv/bin')+os.pathsep+env.get('PATH','');env['PKG_CONFIG_LIBDIR']=str(prefix/'lib/pkgconfig');env['PKG_CONFIG_PATH']=str(prefix/'lib/pkgconfig')
    flags=f'-target {triple} -isysroot {sysroot} -fvisibility=hidden'
    env.update(CC=str(BIN/'clang'),CXX=str(BIN/'clang++'),AR=str(BIN/'ar'),RANLIB=str(BIN/'ranlib'),CFLAGS=flags,CXXFLAGS=flags)
    cmakebase=['cmake','-G','Ninja',f'-DCMAKE_SYSTEM_NAME=iOS',f'-DCMAKE_OSX_SYSROOT={sysroot}',f'-DCMAKE_OSX_ARCHITECTURES={arch}','-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0',f'-DCMAKE_C_COMPILER={BIN/"clang"}',f'-DCMAKE_CXX_COMPILER={BIN/"clang++"}',f'-DCMAKE_INSTALL_PREFIX={prefix}','-DCMAKE_BUILD_TYPE=Release']
    for name,extra in [('glslang',['-DENABLE_OPT=OFF','-DENABLE_GLSLANG_BINARIES=OFF','-DBUILD_TESTING=OFF','-DENABLE_CTEST=OFF']),('vulkan-headers',[])]:
        dst=folder/name
        run(cmakebase+['-S',SOURCES/name,'-B',dst]+extra,env=env);run(['cmake','--build',dst,'--parallel','6'],env=env);run(['cmake','--install',dst],env=env)
    # Upstream Common CMake is macOS-only in its framework list. Adapt only
    # generated pinned source for iOS frameworks; no private Metal APIs.
    common=SOURCES/'moltenvk/Common/CMakeLists.txt'
    text=common.read_text()
    text=text.replace('find_library(APPKIT_LIBRARY AppKit REQUIRED)', 'find_library(APPKIT_LIBRARY UIKit REQUIRED)').replace('find_library(IOKIT_LIBRARY IOKit REQUIRED)', 'set(IOKIT_LIBRARY "")')
    if 'find_library(COREGRAPHICS_LIBRARY' not in text:
        text=text.replace('find_library(METAL_LIBRARY Metal REQUIRED)', 'find_library(METAL_LIBRARY Metal REQUIRED)\nfind_library(COREGRAPHICS_LIBRARY CoreGraphics REQUIRED)')
    if '${METAL_LIBRARY} ${COREGRAPHICS_LIBRARY}' not in text:
        text=text.replace('${METAL_LIBRARY}', '${METAL_LIBRARY} ${COREGRAPHICS_LIBRARY}')
    common.write_text(text)
    target=SOURCES/'moltenvk/MoltenVK/CMakeLists.txt'
    target.write_text(target.read_text().replace('add_library(MoltenVK SHARED', 'add_library(MoltenVK STATIC'))
    mvk=folder/'moltenvk'
    overrides=[]
    for name in ['spirv-cross','spirv-headers','spirv-tools','volk','vulkan-headers','vulkan-tools','cereal']:
        cpm={'spirv-cross':'SPIRV-Cross','spirv-headers':'SPIRV-Headers','spirv-tools':'SPIRV-Tools','volk':'Volk','vulkan-headers':'Vulkan-Headers','vulkan-tools':'Vulkan-Tools','cereal':'cereal'}[name]
        overrides.append(f'-DCPM_{cpm}_SOURCE={SOURCES/name}')
    run(cmakebase+['-S',SOURCES/'moltenvk','-B',mvk,'-DMVK_EXCLUDE_SPIRV_TOOLS=ON','-DMVK_BUILD_SHADER_CONVERTER_TOOL=OFF','-DMVK_CONFIG_USE_METAL_PRIVATE_API=OFF']+overrides,env=env)
    run(['cmake','--build',mvk,'--parallel','6'],env=env);run(['cmake','--install',mvk],env=env)
    # MoltenVK offers standard Vulkan entry points, never a system GL renderer.
    cross=folder/'meson-cross.ini'
    cross.write_text(f"[binaries]\nc = '{BIN/'clang'}'\ncpp = '{BIN/'clang++'}'\nar = '{BIN/'ar'}'\nstrip = '{BIN/'strip'}'\npkg-config = '/opt/homebrew/bin/pkg-config'\n[host_machine]\nsystem = 'darwin'\ncpu_family = '{'aarch64' if arch=='arm64' else 'x86_64'}'\ncpu = '{arch}'\nendian = 'little'\n[built-in options]\nc_args = {['-target',triple,'-isysroot',str(sysroot),'-I'+str(prefix/'include')]!r}\ncpp_args = {['-target',triple,'-isysroot',str(sysroot),'-I'+str(prefix/'include')]!r}\nc_link_args = {['-target',triple,'-isysroot',str(sysroot),'-L'+str(prefix/'lib')]!r}\ncpp_link_args = {['-target',triple,'-isysroot',str(sysroot),'-L'+str(prefix/'lib')]!r}\n[properties]\nneeds_exe_wrapper = true\n")
    # Meson is launched by Homebrew Python, so expose the generated build-only
    # Jinja package path even when its executable interpreter ignores PATH.
    sites=list((WORK/'venv/lib').glob('python*/site-packages'))
    if sites: env['PYTHONPATH']=str(sites[0])+os.pathsep+env.get('PYTHONPATH','')
    for name,opts in [('dav1d' ,['-Denable_tools=false','-Denable_tests=false']),('libplacebo',['-Dvulkan=enabled','-Dvk-proc-addr=disabled','-Dopengl=disabled','-Dd3d11=disabled','-Ddovi=enabled','-Dlibdovi=disabled','-Dglslang=enabled','-Dprefer_static=true',f'-Dvulkan-sdk={prefix}','-Dshaderc=disabled','-Dlcms=disabled','-Ddemos=false','-Dtests=false','-Dbench=false'])]:
        dst=folder/name
        if dst.exists():
            import shutil
            shutil.rmtree(dst)
        run(['meson','setup',dst,SOURCES/name,'--cross-file',cross,'--prefix',prefix,'--libdir','lib','--default-library','static','--buildtype','release']+opts,env=env)
        run(['meson','compile','-C',dst,'-j','6'],env=env);run(['meson','install','-C',dst],env=env)
    pc=prefix/'lib/pkgconfig/libplacebo.pc'
    pctext=pc.read_text()
    if 'Libs.private:' not in pctext:
        pctext+='\nLibs.private: -L${libdir} -lglslang -lglslang-default-resource-limits -lc++\n'
    pc.write_text(pctext)
    # Direct single-owner MoltenVK binding instead of dlopen(system libvulkan).
    vkfile=SOURCES/'ffmpeg/libavutil/hwcontext_vulkan.c'
    vktext=vkfile.read_text()
    prototype='VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *name);'
    if prototype not in vktext:
        vktext=vktext.replace('#include "hwcontext_vulkan.h"', '#include "hwcontext_vulkan.h"\n'+prototype)
    marker='    if (!hwctx->get_proc_addr) {\n        err = load_libvulkan(ctx);'
    if 'if (!hwctx->get_proc_addr) hwctx->get_proc_addr = vkGetInstanceProcAddr;' not in vktext:
        vktext=vktext.replace(marker, '    if (!hwctx->get_proc_addr) hwctx->get_proc_addr = vkGetInstanceProcAddr;\n' + marker)
    vkfile.write_text(vktext)
    render=SOURCES/'ffmpeg/libavfilter/vf_libplacebo.c'
    rendercode=render.read_text()
    rendercode=rendercode.replace('        pl_render_image_mix(in->renderer, &in->mix, &target, &tmp_params);', '        if (!pl_render_image_mix(in->renderer, &in->mix, &target, &tmp_params)) { err = AVERROR_EXTERNAL; goto fail; }')
    rendercode=rendercode.replace('        pl_render_image(s->compositor, &target, &target, opts->params);', '        if (!pl_render_image(s->compositor, &target, &target, opts->params)) { err = AVERROR_EXTERNAL; goto fail; }')
    rendercode=rendercode.replace('        pl_render_image(s->linear_rr, &target, &orig_target, &opts->params);', '        if (!pl_render_image(s->linear_rr, &target, &orig_target, &opts->params)) { err = AVERROR_EXTERNAL; goto fail; }')
    rendercode=rendercode.replace('        pl_render_image(s->linear_rr, NULL, &target, &opts->params);', '        if (!pl_render_image(s->linear_rr, NULL, &target, &opts->params)) { err = AVERROR_EXTERNAL; goto fail; }')
    render.write_text(rendercode)
    encoder=SOURCES/'ffmpeg/libavcodec/videotoolboxenc.c'
    code=encoder.read_text()
    code=code.replace('            if (vtctx->codec_id != AV_CODEC_ID_HEVC)\n                return AVERROR_EXTERNAL;', '            return AVERROR_EXTERNAL;')
    # Express the requested VBV amount as native DataRateLimits bytes/seconds,
    # not an ignored rc_buffer_size field. No refusal can silently downgrade.
    code=code.replace('bytes_per_second_value = max_rate >> 3;', 'bytes_per_second_value = avctx->rc_buffer_size > 0 ? avctx->rc_buffer_size >> 3 : max_rate >> 3;')
    code=code.replace('one_second_value = 1;', 'one_second_value = avctx->rc_buffer_size > 0 ? (double)avctx->rc_buffer_size / max_rate : 1.0;')
    code=code.replace('kCFNumberSInt32Type,\n                                    &one_second_value', 'kCFNumberFloat64Type,\n                                    &one_second_value')
    code=code.replace('int64_t      one_second_value = 0;', 'double       one_second_value = 0;')
    code=code.replace('kCFNumberSInt64Type,\n                                    &one_second_value', 'kCFNumberFloat64Type,\n                                    &one_second_value')
    code=code.replace('        kCMTimeInvalid,\n        frame_dict,', '        frame->duration > 0 ? CMTimeMake(frame->duration * avctx->time_base.num, avctx->time_base.den) : kCMTimeInvalid,\n        frame_dict,')
    code=code.replace('                                             frame->duration > 0 ? CMTimeMake(frame->duration * avctx->time_base.num, avctx->time_base.den) : kCMTimeInvalid,', '                                             kCMTimeInvalid,')
    packet_marker='    pkt->pts = av_rescale_q(pts.value, (AVRational){1, pts.timescale}, avctx->time_base);'
    if 'CMTime duration = CMSampleBufferGetDuration' not in code:
        code=code.replace(packet_marker, '    CMTime duration = CMSampleBufferGetDuration(sample_buffer);\n    if (CMTIME_IS_NUMERIC(duration)) pkt->duration = av_rescale_q(duration.value, (AVRational){1, duration.timescale}, avctx->time_base);\n' + packet_marker)
    encoder.write_text(code)
    ff=folder/'ffmpeg';ff.mkdir(exist_ok=True)
    config=[SOURCES/'ffmpeg/configure',f'--prefix={prefix}','--target-os=darwin',f'--arch={arch}',f'--cc={BIN/"clang"}',f'--cxx={BIN/"clang++"}',f'--ar={BIN/"ar"}',f'--ranlib={BIN/"ranlib"}','--enable-cross-compile',f'--sysroot={sysroot}',f'--extra-cflags={flags} -I{prefix/"include"}',f'--extra-ldflags={flags} -L{prefix/"lib"}','--pkg-config-flags=--static','--disable-programs','--disable-doc','--disable-network','--disable-autodetect','--enable-static','--disable-shared','--disable-gpl','--disable-nonfree','--enable-avcodec','--enable-avformat','--enable-avfilter','--enable-swscale','--enable-swresample','--enable-libdav1d','--enable-libplacebo','--enable-vulkan','--enable-videotoolbox','--enable-audiotoolbox','--enable-protocol=file','--extra-libs=-lMoltenVK -lc++ -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework IOSurface']
    run(config,cwd=ff,env=env);run(['make','-j6'],cwd=ff,env=env);run(['make','install'],cwd=ff,env=env)
    return folder,prefix

def namespace_and_package(folder,prefix,arch,sdk):
    """Rewrite exactly dependency-owned definitions and their references.
    System imports are never in this map. Header macros bind only C symbols.
    C++ symbols are rewritten as complete mangled linker names across closure.
    """
    import re, shutil, hashlib
    nm='/opt/homebrew/opt/llvm/bin/llvm-nm'; objcopy='/opt/homebrew/opt/llvm/bin/llvm-objcopy'
    libs=list((prefix/'lib').glob('*.a'))
    installed_names={x.name for x in libs}
    libs += [x for x in (folder/'moltenvk').rglob('*.a') if x.name not in installed_names]
    unique={str(p.resolve()):p for p in libs};libs=list(unique.values())
    symbols=set()
    for lib in libs:
        output=subprocess.check_output([nm,'--defined-only','--extern-only','--format=posix',str(lib)],text=True)
        for line in output.splitlines():
            fields=line.split()
            if len(fields)>=2 and len(fields[1])==1 and fields[1].isalpha():
                symbol=fields[0]
                if symbol.startswith('_') and not symbol.startswith('__OBJC') and not symbol.startswith('___cxa') and not symbol.startswith('___gxx'):
                    symbols.add(symbol)
    mapping=folder/'namespace.map'
    mapping.write_text(''.join(f'{symbol} _swiftpili_export{symbol}\n' for symbol in sorted(symbols)))
    headers=folder/'headers';shutil.copytree(prefix/'include',headers,dirs_exist_ok=True)
    defines=['#ifndef SWIFTPILI_EXPORT_DEPENDENCY_NAMESPACE','#define SWIFTPILI_EXPORT_DEPENDENCY_NAMESPACE']
    for symbol in sorted(symbols):
        identifier=symbol[1:]
        if re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*',identifier):defines.append(f'#define {identifier} swiftpili_export_{identifier}')
    # FFmpeg public header uses #ifndef av_log2 around its declaration, so
    # macro namespace injection requires an explicit exact public prototype.
    defines += ['int swiftpili_export_av_log2(unsigned value);', 'int swiftpili_export_av_log2_16bit(unsigned value);']
    defines.append('#endif')
    (headers/'ExportNamespace.h').write_text('\n'.join(defines)+'\n')
    # A single umbrella header injects the definition map before public native
    # API includes. App never sees or links unprefixed dependency headers.
    (headers/'ExportMediaDependencies.h').write_text('#include "ExportNamespace.h"\n')
    objects=folder/'namespaced';objects.mkdir(exist_ok=True)
    rewritten=[]
    for n,lib in enumerate(libs):
        dest=objects/(str(n)+'-'+lib.name);run([objcopy,'--redefine-syms='+str(mapping),lib,dest]);rewritten.append(dest)
    combined=folder/'libExportMediaDependencies.a'
    run([BIN/'libtool','-static','-o',combined]+rewritten)
    # Every formerly dependency-owned definition and reference must now use
    # the exact map; no system import is rewritten. This is static link audit.
    original_names=set(symbols)
    remaining=subprocess.check_output([nm,'--extern-only','--format=posix',str(combined)],text=True)
    leaked=[]
    for line in remaining.splitlines():
        fields=line.split()
        if len(fields)>=2 and fields[0] in original_names:leaked.append(fields[0])
    if leaked:raise RuntimeError('Unnamespaced native symbols: '+','.join(sorted(set(leaked))[:20]))
    defined_output=subprocess.check_output([nm,'--defined-only','--extern-only','--format=posix',str(combined)],text=True)
    defined={line.split()[0] for line in defined_output.splitlines() if len(line.split())>1 and len(line.split()[1])==1}
    undefined_output=subprocess.check_output([nm,'--undefined-only','--format=posix',str(combined)],text=True)
    unresolved={line.split()[0] for line in undefined_output.splitlines() if len(line.split())>1 and line.split()[1]=='U'}-defined
    missing=[name for name in unresolved if name.startswith('_swiftpili_export') or name.startswith('__ZN15MVK_spirv_cross')]
    if missing:raise RuntimeError('Incomplete export dependency closure: '+','.join(sorted(missing)[:20]))
    # Compile real App C adapter against matching namespaced headers.
    sysroot=DEVELOPER/'Platforms'/('iPhoneOS.platform' if sdk=='iphoneos' else 'iPhoneSimulator.platform')/'Developer/SDKs'/('iPhoneOS.sdk' if sdk=='iphoneos' else 'iPhoneSimulator.sdk')
    triple=f'{arch}-apple-ios18.0'+('' if sdk=='iphoneos' else '-simulator')
    run([BIN/'clang','-target',triple,'-isysroot',sysroot,'-std=c11','-Wall','-Wextra','-include',headers/'ExportNamespace.h','-I',headers,'-I',PACKAGE/'Sources/CMediaExport/include','-c',PACKAGE/'Sources/CMediaExport/MediaExport.c','-o',folder/'MediaExport.o'])
    receipt={'pins':PINS,'sdk':sdk,'arch':arch,'archive_sha256':hashlib.sha256(combined.read_bytes()).hexdigest(),'namespace_symbols':len(symbols),'headers':str(headers),'archive':str(combined)}
    (folder/'receipt.json').write_text(json.dumps(receipt,indent=2))
    return combined,headers

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--sdk',choices=['iphoneos','iphonesimulator'],default='iphoneos');parser.add_argument('--arch',choices=['arm64','x86_64'],default='arm64');parser.add_argument('--package-only',action='store_true');args=parser.parse_args()
    if args.package_only:
        device=WORK/'iphoneos-arm64';simulator=WORK/'iphonesimulator-arm64'
        destination=PACKAGE/'Vendor/ExportMediaDependencies.xcframework'
        import shutil
        if destination.exists():shutil.rmtree(destination)
        destination.parent.mkdir(parents=True,exist_ok=True)
        run([DEVELOPER/'usr/bin/xcodebuild','-create-xcframework','-library',device/'libExportMediaDependencies.a','-headers',device/'headers','-library',simulator/'libExportMediaDependencies.a','-headers',simulator/'headers','-output',destination])
    else:
        extract();folder,prefix=build(args.arch,args.sdk);namespace_and_package(folder,prefix,args.arch,args.sdk)
