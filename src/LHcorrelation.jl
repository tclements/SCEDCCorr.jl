export prepare_LH, LH_to_FFT, read_and_remove, all2all, LH_check_time, split_by_month
export LH_corr, LH_query, LH_download, LH_day_corr, LH_write_combine, LH_stack

function prepare_LH(
    files::AbstractArray,
    XMLDIR::String,
    freqmin::Real,
    freqmax::Real,
    cc_len::Real,
    cc_step::Real,
)
    sort!(files)
    fileE, fileN, fileZ = files
    RESP = read_resp(fileE,XMLDIR)

    # read and remove instrument resp
    E = read_and_remove(fileE,freqmin,freqmax,RESP)
    N = read_and_remove(fileN,freqmin,freqmax,RESP)
    Z = read_and_remove(fileZ,freqmin,freqmax,RESP)

    # check for problem with single data point gap 
    E.t[1][2,2] = 0
    N.t[1][2,2] = 0
    Z.t[1][2,2] = 0

    # synchronize E and N starttimes/endtimes for normalization 
    S = E + N
    sync!(S,s="last",t="first")
    E = S[1:1]
    N = S[2:2]

    # bandpass between 15 and 50 seconds 
    Efilt = filtfilt(E,rt="Bandpass",fl=1/50.,fh=1/15.,np=2)
    Nfilt = filtfilt(N,rt="Bandpass",fl=1/50.,fh=1/15.,np=2)
    Zfilt = filtfilt(Z,rt="Bandpass",fl=1/50.,fh=1/15.,np=2)

    # normalize Z comp with 128-second weight 
    weights = smooth(abs.(Zfilt.x[1]),64)
    Z.x[1] ./= weights 

    # normalize E and N comps with 128-second weight 
    Eweights = smooth(abs.(Efilt.x[1]),64)
    Nweights = smooth(abs.(Nfilt.x[1]),64)
    weights = maximum(hcat([Eweights,Nweights]...),dims=2)[:]
    E.x[1] ./= weights
    N.x[1] ./= weights 
    
    # check for instance where any of E, N, or Z is very small
    # convert to FFT 
    if LH_check_time(Z,cc_len,cc_step) & LH_check_time(E,cc_len,cc_step)
        return LH_to_FFT(E,N,Z,cc_len,cc_step)
    else
        return [FFTData() for _ = 1:3]
    end
end

function LH_to_FFT(E,N,Z,cc_len,cc_step)
    Eraw = RawData(E,cc_len,cc_step)
    Nraw = RawData(N,cc_len,cc_step)
    Zraw = RawData(Z,cc_len,cc_step)

    # simple processing 
    detrend!(Eraw)
    detrend!(Nraw)
    detrend!(Zraw)
    taper!(Eraw,max_length=100.)
    taper!(Nraw,max_length=100.)
    taper!(Zraw,max_length=100.)

    # convert to fft 
    Efft = rfft(Eraw)
    Nfft = rfft(Nraw)
    Zfft = rfft(Zraw)

    # whiten E,N,Z components with 100 s amplitude smoothing 
    Efft.fft ./= smooth(abs.(Efft.fft),50)
    Nfft.fft ./= smooth(abs.(Efft.fft),50)
    Zfft.fft ./= smooth(abs.(Zfft.fft),50)
    return [Efft, Nfft, Zfft] 
end

function read_and_remove(file::String,freqmin::Real,freqmax::Real,RESP::SeisData)
    S = read_data("mseed",file)
    merge!(S)
    detrend!(S)
    ungap!(S)
    taper!(S,t_max=50.)
    phase_shift!(S)
    filtfilt!(S,rt="Bandpass",fl=freqmin,fh=freqmax,np=2)
    net,sta,loc,chan = split(S.id[1],'.')
    ind = findfirst(RESP.id .== S[1].id)
    S.loc[1] = RESP[ind].loc
    S.gain[1] = RESP[ind].gain
    S.resp[1] = RESP[ind].resp
    remove_resp!(S)
    return S
end

function all2all(
    FFT1::AbstractArray{FFTData},
    FFT2::AbstractArray{FFTData},
    maxlag::Real,
)
    @assert size(FFT1,1) == 3
    @assert size(FFT2,1) == 3 
    C = Array{CorrData}(undef,9)
    for ii = 1:3
        for jj = 1:3
            C[(ii-1) * 3 + jj] = correlate(FFT1[ii],FFT2[jj],maxlag)
        end
    end
    return C
end

function LH_corr(d::Date,FFTS::AbstractArray,maxlag::Real,CORRDIR::String)
    N = size(FFTS,1)
    comps = ["EE","EN","EZ","NE","NN","NZ","ZE","ZN","ZZ"]
    filename = joinpath(CORRDIR,"$(date2yyyyjjj(d)).jld2")
    file = jldopen(filename, "a+")
    for ii = 1:N-1
        for jj = ii+1:N
            # cross-correlate 
            if check_intersect(FFTS[ii],FFTS[jj])
                CS = all2all(FFTS[ii],FFTS[jj],maxlag)
                stack!.(CS)
                net1,sta1,loc1,chan1,net2,sta2,loc2,chan2 = split(CS[1].name,'.')
                netsta = join([net1,sta1,net2,sta2],".")

                # save to file
                for kk = 1:9
                    compname = "$netsta/$(CS[kk].comp)/$(CS[kk].id)"
                    file[compname] = CS[kk]
                end
            end
        end
    end
    close(file)
    return nothing
end

function LH_day_corr(d::Date,aws,DATADIR,CORRDIR,XMLDIR,freqmin,freqmax,cc_len,cc_step,maxlag)
    println("Correlating $d")
    filelist = LH_query(aws,d)
    LH_download(aws,filelist,DATADIR)
    infiles = joinpath.(DATADIR,filelist)
    ZNEfiles = prunefiles(infiles)
    # check for day with bad files
    if !isempty(ZNEfiles)
        FFTS = map(x -> prepare_LH(x,XMLDIR,freqmin,freqmax,cc_len,cc_step),ZNEfiles)
        LH_corr(d,FFTS,maxlag,CORRDIR)
    end
    rm.(infiles)
    return nothing
end

function LH_query(aws::AWSConfig,d::TimeType)
    # download index for day
    path = indexpath(d)
    filedf = CSV.File(IOBuffer(s3_get(aws,"scedc-pds",path))) |> DataFrame
    filedf = filedf[filedf[:,:net] .== "CI",:]
    filedf = filedf[filedf[:,:location] .== "--",:]
    filedf = filedf[occursin.("LH",filedf[:,:seedchan]),:]
    return scedcpath.(filedf[:ms_filename])
end

function LH_download(aws,filelist,OUTDIR)
    outfiles = [joinpath(OUTDIR,f) for f in filelist]
    filedir = unique([dirname(f) for f in outfiles])
	for ii = 1:length(filedir)
		if !isdir(filedir[ii])
			mkpath(filedir[ii])
		end
    end
    for ii = 1:length(filelist)
        s3_get_file(aws,"scedc-pds",filelist[ii],outfiles[ii])
    end
    return nothing
end

function LH_stack(combname,STACKDIR)
    if !isdir(STACKDIR)
        mkpath(STACKDIR)
    end

    comps = ["EE","EN","EZ","NE","NN","NZ","ZE","ZN","ZZ"]
    # open comb and stack file 
    combfile = jldopen(combname,"r")
    stackname = joinpath(STACKDIR,basename(combname))
    stackfile = jldopen(stackname,"a+")
    ks = keys(combfile)
    N = length(ks)

    # stack over each time month
    for ii = 1:N
        for jj = 1:length(comps)
            chan = ks[ii] * "/" * comps[jj]
            days = keys(combfile[chan])
            num_days  = length(days)

            # get sizes of all corrs
            C = CorrData()
            for kk = 1:num_days
                C += combfile[chan * "/" * days[kk]]
            end

            stack!(C,allstack=true)
            push!(C.notes,"$(now()) ¦ processing ¦ stack! ¦ $num_days days")
            stackfile[chan] = C
        end
    end
    close(combfile)
    close(stackfile)
    return nothing 
end

function getkeys(file)
    ks = keys(file)
    out = String[]
    sizehint!(out,size(ks,1) * 9)
    for ii = 1:size(ks,1)
        compks = ks[ii] .* "/" .* keys(file[ks[ii]])
        for jj = 1:size(compks,1)
            push!(out,compks[jj] * "/" * keys(file[compks[jj]])[1])
        end
    end
    return out
end

function LH_write_combine(files,COMBDIR)
    if !isdir(COMBDIR)
        mkpath(COMBDIR)
    end

    # open COMBfile 
    yyyy = parse(Int,basename(files[1])[1:4]) 
    mm = month(yyyyjjj2date(replace(basename(files[1])[1:8],"_"=>"")))
    combname = joinpath(
                            COMBDIR,
                            string(yyyy) 
                            * "_" * lpad(string(mm),2,"0")
                             * ".jld2")
    combfile = jldopen(combname,"a+")
    for ii = 1:size(files,1)
        file = jldopen(files[ii],"r")
        filekeys = getkeys(file)
        for jj = 1:size(filekeys,1)
            combfile[filekeys[jj]] = file[filekeys[jj]]
        end
        close(file)
    end
    close(combfile)
    return nothing 
end

function LH_check_time(S::SeisData,cc_len,cc_step)
    starttime = SeisIO.starttime(S.t[1],S.fs[1]) * SeisIO.μs
    endtime = SeisIO.endtime(S.t[1],S.fs[1]) * SeisIO.μs

    # check if data is within a window 
    tot = endtime - starttime + 1 ./ S.fs[1]
    if tot > cc_len * 2 
        return true
    elseif tot < cc_len 
        return false
    end
    
    # tricky case where cc_len < length(S[1].x) < 2 * cc_len
    starttime = round(starttime,digits=4) 
    endtime = round(endtime,digits=4)
    ideal_start = d2u(DateTime(Date(u2d(starttime))))
    starts = Array(range(ideal_start,stop=endtime,step=cc_step))
    ends = starts .+ cc_len .- 1. / S.fs[1] 
    startind = findfirst(x -> x >= starttime, starts)
    endind = findlast(x -> x <= endtime,ends)
    if endind < startind 
        return false
    else
        return true
    end
end

function split_by_month(files)
    ds = [replace.(replace.(basename.(f),"_"=>""),".jld2"=>"") for f in files]
    dates = [yyyyjjj2date(d) for d in ds]
    ms = month.(dates)
    months = Any[]
    for ii = 1:maximum(ms)
        ind = findall(ms .== ii)
        push!(months,files[ind])
    end
    return months
end

function check_intersect(FFT1,FFT2)
    for ii = 1:3
        for jj = 1:3
            if length(intersect(FFT1[ii].t,FFT2[jj].t)) == 0 
                return false
            end
        end
    end
    return true 
end
