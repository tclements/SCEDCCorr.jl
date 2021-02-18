export prunefiles, upload_par, read_resp, yyyyjjj2date, date2yyyyjjj, nancorr
export XML_download, indexpath, scedcpath, size_check, update_resp_t!, sync_resp, get_gaps

function prunefiles(filelist::AbstractArray; minfraction = 0.25, maxfraction = 2., minsize=20000)
    if length(filelist) == 0
	    return []
    end
    
    files = size_check(filelist,minfraction=minfraction,maxfraction=maxfraction, minsize=minsize)

    # get individual stations
    stations = unique([replace(basename(f)[1:7],"_"=>"") for f in files])
    infiles = []
    for jj in eachindex(stations)
	    ind = findall(occursin.(stations[jj],files))
        if length(ind) != 3
	        continue
        end
        push!(infiles,files[ind])
    end
	return infiles
end

function size_check(filelist::AbstractArray; minfraction = 0.25, maxfraction = 2., minsize=20000)
	files = deepcopy(filelist)
    fsizes = [filesize(f) for f in files]

    # check for minimum and maximum sizes relative to median 
    ind1 = findall((fsizes .< median(fsizes) * minfraction) .| (fsizes .> median(fsizes) * maxfraction))
    ind2 = findall(fsizes .< minsize)
    deleteat!(files,unique([ind1;ind2]))
    return files
end

function yyyyjjj2date(yearday::String)
    @assert occursin(r"[1-2][0-9][0-9][0-9][0-3][0-9][0-9]",yearday)
    yint = parse(Int,yearday[1:4])
    dint = parse(Int,yearday[5:end])
    @assert dint <= 366 "Input day must be less than or equal to 366"
    return DateTime(yint) + Day(dint-1)
end

function date2yyyyjjj(d::TimeType)
    return "$(year(d))_$(lpad(dayofyear(d),3,"0"))"
end

function upload_par(aws::AWSConfig,output_bucket::String,s3file::String,ec2file::String)
    println("Uploading file $ec2file")
    s3_put(aws,output_bucket,s3file,read(ec2file))
end
upload_par(a...) = upload_par(global_aws_config(region="us-west-2"),a...)

function read_resp(file::String,XMLDIR::String)
    s = yyyyjjj2date(file[end-9:end-3])
	t = s + Day(1)
	s = Dates.format(s, "yyyy-mm-dd HH:MM:SS")
	t = Dates.format(t, "yyyy-mm-dd HH:MM:SS")
	net = basename(file)[1:2]
	sta = split(basename(file),"_")[1][3:end]
	instpath = joinpath(XMLDIR,net * '_' * sta * ".xml" )
    return read_meta("sxml",instpath,s=s,t=t)
end

function XML_download(aws,XMLDIR)
    if !isdir(XMLDIR)
        mkpath(XMLDIR)
    end
    req = collect(s3_list_objects(aws,"scedc-pds","FDSNstationXML/CI/"))
    xmlin = [r["Key"] for r in req]
    xmlout = joinpath.(XMLDIR,basename.(xmlin))
    for ii = 1:length(xmlin)
        s3_get_file(aws,"scedc-pds",xmlin[ii],xmlout[ii])
    end
    return nothing
end
XML_download(XMLDIR) = XML_download(global_aws_config(region="us-west-2"),XMLDIR)

function indexpath(d::Date)
    days = (d - Date(Year(d))).value + 1
    n = ndigits(days)
	jstr = ('0' ^ (3 - n)) * string(days)
	ystr = string(Year(d).value)
    outstring = "continuous_waveforms/index/csv/year="
    outstring *= ystr * "/year_doy="
    outstring *= ystr * '_' * jstr
    outstring *= "/$(ystr)_$(jstr)_waveform_index.csv"
    return outstring
end

"""
  scedcpath(filename)
Convert filename to scedc-pds path.
"""
function scedcpath(filename::String)
    year = filename[14:17]
    day = filename[18:20]
    return "continuous_waveforms/" * year * '/' * year * '_' * day * '/' * filename
end

"""
  update_resp_t!(S)

Add time matrices for instrument response stored in SeisData
"""
function update_resp_t!(S::SeisData)
    for ii = 1:S.n
        S.t[ii] = [1 S.misc[ii]["startDate"];0 S.misc[ii]["endDate"]]
    end
    return nothing 
end

"""
  sync_resp(S,s,t)

Prune SeisData such that response are within statrttime `s` 
"""
function sync_resp(S::SeisData,s::Int64,t::Int64)
    todelete = [] 
    for ii = 1:S.n 
        if S.t[ii][1,2] > t
            append!(todelete,ii)
        elseif S.t[ii][2,2] < s 
            append!(todelete,ii)
        end
    end
    ind = setdiff(1:S.n,todelete)
    return S[ind]
end

function get_gaps(S::SeisData)
    ngaps = zeros(Int,S.n)
    for ii = 1:S.n
        ngaps[ii] = size(S.t[ii],1) - 2
    end
    return ngaps
end

function nancorr(S::SeisData, d::DateTime, fs::Real, maxlag::Real)
    C = CorrData()
    T = eltype(S.x[1])
    C.t = [d2u(d)]
    C.corr = zeros(T,convert(Int,2 * fs * maxlag) + 1,1)
    C.corr .= NaN
    return C
end