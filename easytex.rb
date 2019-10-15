#!/usr/bin/ruby
require 'zlib'

def tex2png(data)
	def _interleave(n)
		n=(n^(n<<16))&0x0000ffff0000ffff
		n=(n^(n<<8 ))&0x00ff00ff00ff00ff
		n=(n^(n<<4 ))&0x0f0f0f0f0f0f0f0f
		n=(n^(n<<2 ))&0x3333333333333333
		n=(n^(n<<1 ))&0x5555555555555555
	end
	def interleave(hi,lo)
		_interleave(hi)<<1 | _interleave(lo)
	end
	def _deinterleave(n)
		n&=0x5555555555555555
		n=(n^(n>>1 ))&0x3333333333333333
		n=(n^(n>>2 ))&0x0f0f0f0f0f0f0f0f
		n=(n^(n>>4 ))&0x00ff00ff00ff00ff
		n=(n^(n>>8 ))&0x0000ffff0000ffff
		n=(n^(n>>16))&0x00000000ffffffff
	end
	def deinterleave(n)
		[_deinterleave(n),_deinterleave(n>>1)]
	end

	def chunk(type, data)
		[data.bytesize, type, data, Zlib.crc32(type + data)].pack('NA4A*N')
	end

	mode = data[4].ord
	type = data[7].ord
	if mode==0x07 || mode.ord==0x09
		width=data[13].ord*256|data[12].ord
		height=data[14].ord*8
	elsif mode==0x9d
		width=data[11].ord*32
=begin
		if data[13].ord==0x28
			height=512*2
		elsif data[13].ord==0x2b
			height=256
		else
			raise 'xxx %d'%data[13].ord
		end
=end
		if width==0
			return nil
		end
		data=data[0x04..-1] # there are 4bytes shift
	else
		return nil
	end
	
	if type==0x20
		#RGBA8888
		#why byte order is opposite against 4444?
		if mode==0x9d
			datn=data[16..-1].unpack('L>*')
			height = datn.size/width # fixme...
			data=' '*16+datn.map{|word|
				(word&0xff000000)>>24<<8 |
				(word&0x00ff0000)>>16<<16 |
				(word&0x0000ff00)>>8<<24 |
				(word&0x000000ff)
			}.pack('L>*')
		end
	elsif type==0x10
		#RGBA4444
		datn=data[16..-1].unpack('S<*')
		data=' '*16+datn.map{|word|
			(word&0xf000)>>(12-4)<<24 |
			(word&0x0f00)>>(8-4)<<16 |
			(word&0x00f0)>>(4-4)<<8 |
			(word&0x000f)>>(0-4)<<0
		}.pack('L>*')
	elsif type==0x04
		# PVRTC
		datn=data[16..-1].unpack('L<*')
		w=width/4
		h=height/4
		out1=[0]*(w*h)
		out2=[0]*(w*h)
		outm=[0]*(width*height)
		h.times{|y|w.times{|x|
			k=interleave(x,y)
			mod_data=datn[k*2]
			word1,word2=datn[k*2+1].divmod(65536)
			color1 = word1[15]==0 ? [
				(word1&0x0f00)>>(8-4),
				(word1&0x00f0)>>(4-4),
				(word1&0x000f)>>(0-4),
				(word1&0x7000)>>(12-5),
			] : [
				(word1&0x7c00)>>(10-3),
				(word1&0x03e0)>>(5-3),
				(word1&0x001f)>>(0-3),
				255,
			]
			color2 = word2[15]==0 ? [
				(word2&0x0f00)>>(8-4),
				(word2&0x00f0)>>(4-4),
				(word2&0x000e)>>(1-5),
				(word2&0x7000)>>(12-5),
			] : [
				(word2&0x7c00)>>(10-3),
				(word2&0x03e0)>>(5-3),
				(word2&0x001e)>>(1-4),
				255,
			]
			mode = word2[0]
			4.times{|my|4.times{|mx|
				mod_data,mod = mod_data.divmod(4)
				if mode>0
					v=[0,4,9,8][mod]
				else
					v=[0,3,5,8][mod]
				end
				outm[x*4+mx+(y*4+my)*width]=v
			}}
			out1[y*w+x]=color1
			out2[y*w+x]=color2
		}}
		#bilinear-resample out1 and out2
		large1,large2=[out1,out2].map{|out|
			large=[0]*(height*width)
			height.times{|y|width.times{|x|
				# todo: proper handling of picture edge
				large[(y+2)%height*width+(x+2)%width]=4.times.map{|i|(
					(4-x%4)*(4-y%4) * out[(y/4+0)%h*w + (x/4+0)%w][i] +
					(x%4)*(4-y%4)   * out[(y/4+0)%h*w + (x/4+1)%w][i] +
					(4-x%4)*(y%4)   * out[(y/4+1)%h*w + (x/4+0)%w][i] +
					(x%4)*(y%4)     * out[(y/4+1)%h*w + (x/4+1)%w][i]
				)/16}
			}}
			large
		}
		data=' '*16
		height.times{|y|width.times{|x|
			color1=large1[y*width+x]
			color2=large2[y*width+x]
			mod1=outm[y*width+x]
			mod2=8-mod1
			color=mod1==9 ? [0]*4 : 4.times.map{|i|
				(color1[i]*mod1+color2[i]*mod2)/8
			}
			data<<color.pack('C4')
		}}
	else
		return nil # unknown format
	end

	# build png using raw RGBA data.
	s="\x89PNG\r\n\x1a\n".dup
	s.force_encoding('ASCII-8BIT')
	# bitdepth=8, colortype=6 (color w/alpha)
	s<<chunk("IHDR",[width, height, 8, 6, 0, 0, 0].pack("NNCCCCC"))
	idat=''.dup
	height.times{|i|
		line=data[16+i*4*width,4*width]
		idat<<"\x00"+line
	}
	s<<chunk("IDAT",Zlib::Deflate.deflate(idat))
	s<<chunk("IEND","")
	s
end

if __FILE__==$0
	if ARGV.size<1
		STDERR.puts 'easytex texpath'
		exit
	end
	texpath = ARGV[0]

	tex=File.binread(texpath)
	png=tex2png(tex)
	if !png
		STDERR.puts 'processing failed'
	else
		namewithoutext = texpath.index('.') ? texpath[0...texpath.index('.')] : texpath
		File.binwrite(namewithoutext+'.png',png)
	end
end
