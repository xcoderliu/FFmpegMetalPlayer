this is a ffmpeg demo of osx app and based on kxmovie & use metal to render video frames

###简介
这一份教程是关于如何使用最新的 FFmpeg 3.2.4 进行音视频的编解码,以及如何使用 metal 对解码之后的帧数据进行渲染. 感觉现在的 ffmpeg 教程都是基于 2.x 的所以就自己鼓捣了一下,希望和大家一起讨论交流共同进步. 本教程的 [github 源码](https://github.com/xcoderliu/FFmpegMetalPlayer) (运行环境 OSX)也会跟随本教程持续更新.因为作者有全职工作所以不能保证更新进度望大家理解. 本教程也参考了 [kxMovie](https://github.com/kolyvan/kxmovie) 感谢作者.

###音视频基础介绍
首先,大家需要有一定的基础知识,对于音视频其实大家都知道所谓的视频就是一帧一帧的图片组合而成.随着时间正确的渲染出图片就能播放一个视频. 同样的音频就是在正确的时间播放出对应的声音.在对的时间贴上对的图对的声音就能播放完整的电影了.

###FFmpeg 介绍
FFmpeg是一个自由软件，可以运行音频和视频多种格式的录影、转换、流功能[1]，包含了libavcodec——这是一个用于多个项目中音频和视频的解码器库，以及libavformat——一个音频与视频格式转换库。
“FFmpeg”这个单词中的“FF”指的是“Fast Forward”[2]。有些新手写信给“FFmpeg”的项目负责人，询问FF是不是代表“Fast Free”或者“Fast Fourier”等意思，“FFmpeg”的项目负责人回信说：“Just for the record, the original meaning of "FF" in FFmpeg is "Fast Forward"...”
这个项目最初是由Fabrice Bellard发起的，而现在是由Michael Niedermayer在进行维护。许多FFmpeg的开发者同时也是MPlayer项目的成员，FFmpeg在MPlayer项目中是被设计为服务器版本进行开发。
2011年3月13日，FFmpeg部分开发人士决定另组Libav，同时制定了一套关于项目继续发展和维护的规则。

#### FFmpeg 组件
- ffmpeg——一个命令行工具，用来对视频文件转换格式，也支持对电视卡即时编码
- ffserver——一个HTTP多媒体即时广播流服务器，支持时光平移
- ffplay——一个简单的播放器，基于SDL与FFmpeg库
- libavcodec——包含全部FFmpeg音频/视频编解码库
- libavformat——包含demuxers和muxer库
- libavutil——包含一些工具库
- libpostproc——对于视频做前处理的库
- libswscale——对于视频作缩放的库

###利用 FFmpeg 视频解码
在项目中我们可以创建一个负责音视频解码的类,命名为 xxDecoder.mm ,在初始化函数中调用 **av_register_all();** 方法初始化 FFmpeg,然后开始对视频进行编解码.

#### 检测音视频文件是否可以解码
一些比较简单的工作在本教程中我就省略了,比如创建一个 NSOpenPanel 去选取音视频文件.拿到文件之后我们需要对文件的传入路径做一下分析看它是不是一个本地文件,因为 FFmpeg 也支持多媒体即使广流服务器.(本教程截止 2017.02.28 播放器仅支持本地播放 实际上还没解码音频😅) 假如是流媒体文件我们需要调用 **avformat_network_init();** .
首先我们需要创建一个 **AVFormatContext** 实例,这个实例对我们来说是非常重要的需要作为我们解码类的一个成员确定可以打开文件之后进行成员变量的赋值.

```
//创建 AVFormatContext 实例
    AVFormatContext *formatCtx = NULL;
    //容错回调
    if (_interruptCallback) {
        
        formatCtx = avformat_alloc_context();
        if (!formatCtx)
            return lzmMediaErrorOpenFile;
        
        AVIOInterruptCB cb = {interrupt_callback, (__bridge void *)(self)};
        formatCtx->interrupt_callback = cb;
    }
```
以上代码就是创建一个 AVFormatContext 实例然后创建了一个回调假如解码出现错误能够及时回调做出相应的处理.

接下来使用 FFmpeg 接口打开传入的文件路径, **avformat_open_input** 没有出错的话,我们还需要检查是否能打开音视频流.一切 OK 就可以保存这样一个 AVFormatContext 实例.

```
    //打开文件获得错误码
    int err_code = avformat_open_input(&formatCtx, [path cStringUsingEncoding:NSUTF8StringEncoding], NULL, NULL);
    //出现错误
    if (err_code != 0) {
        
        if (formatCtx)
            avformat_free_context(formatCtx);
        
        char* buf[1024];
        av_strerror(err_code, (char*)buf, 1024);
        printf("Couldn't open file %s: %d(%s)", [path cStringUsingEncoding: NSUTF8StringEncoding], err_code, (char*)buf);
        
        return lzmMediaErrorOpenFile;
    }
    
	//获取音视频流
    if (avformat_find_stream_info(formatCtx, NULL) < 0) {
        
        avformat_close_input(&formatCtx);
        return lzmMediaErrorStreamInfoNotFound;
    }
    
    //打印音视频的具体信息
    av_dump_format(formatCtx, 0, [path.lastPathComponent cStringUsingEncoding: NSUTF8StringEncoding], 0);
    
    _formatCtx = formatCtx;
```

以上代码基本上就是确定了视频文件的有效性,以及文件可被解码.
接下来就是具体解码视频的过程,FFmpeg 解码是根据时间来解码出当时的视频图片,所以首先我们自己写一个定时器,然后再定时器中不断调用解码的函数并传入需要解码的时间.
FFmpeg 3.x 解码是用 **avcodec_send_packet** 和 **avcodec_receive_frame**.

```
- (NSArray *) decodeFrames: (CGFloat) minDuration
{
    if (_videoStream == -1 &&
        _audioStream == -1)
        return nil;
    
    NSMutableArray *result = [NSMutableArray array];
    
    AVPacket packet;//Usually single video frame or several complete audio frames.
    
    CGFloat decodedDuration = 0;
    
    BOOL finished = NO;
    
    while (!finished) {
        
        if (av_read_frame(_formatCtx, &packet) < 0) {
            _isEOF = YES;
            break;
        }
        
        if (packet.stream_index ==_videoStream) {
            
            int errorcode = avcodec_send_packet(_videoCodecCtx, &packet);
            if (errorcode != 0) {
                break;
            }
            errorcode = avcodec_receive_frame(_videoCodecCtx, _videoFrame);
            if (errorcode != 0) {
                break;
            }
            
            lzmVideoFrame *frame = [self handleVideoFrame];
            if (frame) {
                
                [result addObject:frame];
                
                _position = frame.position;
                decodedDuration += frame.duration;
                if (decodedDuration > minDuration)
                    finished = YES;
            }  
        }     
    return result;
}
``` 

以上代码中最关键的是:

```
 avcodec_send_packet(_videoCodecCtx, &packet);
 avcodec_receive_frame(_videoCodecCtx, _videoFrame
```

这段代码能够将 _videoFrame 赋值.然后经过我们的处理函数 **handleVideoFrame** 将 FFmpeg 的 frame 数据转换成我们的自定义 frame 数据.

