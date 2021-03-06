function [dat, tissue, RF, motion] = sweep_sim_EPG_2(tissue, RF, motion)
%% Laurence Jackson, BME, KCL, 2018
%
% Simulates pulse profile moving across tissue with motion and flow
% consideration
%
% INPUTS::
%   tissue  - tissue struct with fields
%       T1      - T1 of tissue
%       T2      - T2 of tissue
%       length  - length of tissue to simulate
%
%   RF      - sequence struct with fields
%       profile - RF profile (flip radians vs time)
%       TR      - TR
%       thk     - nominal slice thickness
%       swp     - sweep rate
%
% OUTPUTS::
%       dat     - return data structure with fields
%       s0      - signal
%       flipmat - applied flips (time vs zloc)
%

%% Hidden options - shouldnt need to be changed in most cases
% tissue_multiplier = 5; % resolution of tissue vector
RF.range = 10; % +/-mm to simulate rf pulse over (i.e. extend of sidebands to include)
elements_per_mm = 25; % elements of simulation matrix per mm, can speed things up
offload = 1; % offload to remote machine if set up

%% calculated values

[RF.profile, zz,~] = pulse_profile(RF); % simulate pulse profile

if RF.block ==1
    RF.profile(RF.profile>(0.5*(max(RF.profile)))) = max(RF.profile);
    RF.profile(RF.profile<(0.5*(max(RF.profile)))) = 0;
end

RF.pulseshift = 0.01.*RF.swp.*RF.thk; % pulse shift in m (RF.swp = % slice moved per pulse)

if RF.seqspec == 1
    RF.npulses = RF.npe * RF.ndyn *  RF.nslice;
    warning('RF.npulses is being overridden by RF.seqspec and RF.npe -- npulses is now %d',RF.npulses)
    
    if (RF.match_swp == 1)
        % match sweep rate to seqspec
        RF.pulseshift = ((RF.nslice) * (RF.thk + RF.slicegap)) / RF.npulses;
        RF.swp = (RF.pulseshift * 100) / (RF.thk);
        warning('RF.swp is being overridden by RF.seqspec -- RF.swp is now %d', RF.swp)
    end
    
elseif RF.pulseshift == 0
    RF.nslice = ceil(RF.npulses./RF.npe); % estimated number of slices to make sure enough tissue is simulated
end

RF.flip = rad2deg(max(RF.profile)); % approximate flip angle
RF.sweepdur = RF.npulses.*RF.TR*0.001; % sweep duration in seconds

%% calculate motion vectorss
if isfield(motion,'custom')
   motion_resp = motion.custom;
else
   motion_resp = sin(linspace(0,2*pi*RF.sweepdur*(motion.respfreq),RF.npulses)).*(motion.respmag./2);
end

motion.motion_resp = motion_resp;

%% Introduce flow component
motion.flow_per_pulse = 0;
if ~motion.flow==0   
    motion.flow_per_pulse = (motion.flow * RF.sweepdur) / RF.npulses; % displacement per pulse from flow
    motion.flow_dist = motion.flow_per_pulse .* RF.npulses;
end

%% define tissue
% tissue.min = min([0,max(motion_resp),-1.*(motion.flow_per_pulse.*RF.npulses)]); % flow is negative in this coordinate system
tissue.min = min([0,-max(motion_resp),-1.*(motion.flow_per_pulse.*RF.npulses)]); % flow is negative in this coordinate system

% CHECKTHIS: changes tissue.min contribution to tissue.length to abs value
% tissue.length = (RF.range*1e-3) + (tissue.min) + ((RF.thk + RF.slicegap) * RF.nslice) + (RF.pulseshift.*RF.npulses) + (abs(motion.flow_per_pulse).*RF.npulses);
tissue.length = (2*RF.range*1e-3) + abs(tissue.min) + ((RF.thk + RF.slicegap) * (RF.nslice-1)) + (RF.pulseshift.*RF.npulses) + (abs(motion.flow_per_pulse).*RF.npulses);

tissue_resolution = ceil((abs(tissue.length - tissue.min)*1e3) * elements_per_mm); % elements per mm
tissue.vec = linspace(tissue.min,tissue.length,tissue_resolution);

%% print final simulation paramters
print_sim_info(tissue, RF, motion)

%% Produce flipmat
zzabs = (zz) + abs(min(zz));
flipmat = zeros(RF.npulses,length(tissue.vec));
sliceshift = 0;
firstpulse = [1];
sliceidx = 1;
dynidx = 1;

switch RF.sliceorder
    case 'ascending'
        slicev = 0:(RF.nslice-1);
    case 'descending'
        slicev = (RF.nslice-1):-1:0;
    case 'odd-even'
        v = 0:(RF.nslice-1);
        v_odd = v(rem(v,2)~=0);
        v_even = v(rem(v,2)==0);
        slicev = [v_even v_odd];
    case 'random'
        vv = 0:(RF.nslice-1);
        slicev = vv(randperm(length(vv)));
    otherwise
        error('Check RF.sliceorder definitition')
end

for puls = 1:RF.npulses
    if RF.seqspec == 1 % npulses defined by nslices and ndyns
        switch RF.dynorder
            case 'slices'
                
                if RF.pulseshift == 0 && mod(puls-1,RF.npe) == 0 % not sweep and first pulse in 2D k-space
                    
                    sliceshift = slicev(sliceidx).*(RF.thk + RF.slicegap);
                    
                    if sliceidx < RF.nslice
                        sliceidx = sliceidx + 1;
                    else
                        dynidx = dynidx + 1;
                        sliceidx = 1;
                    end
                    
                    firstpulse = [firstpulse; puls];
                    
                end
                
            case 'dynamics'
                if RF.pulseshift == 0 && mod(puls-1,RF.npe) == 0
                    sliceshift = slicev(sliceidx).*(RF.thk + RF.slicegap);
                    
                    if dynidx < RF.ndyn
                        dynidx = dynidx + 1;
                    else
                        sliceidx = sliceidx + 1;
                        dynidx = 1;
                    end
                    
                    firstpulse = [firstpulse; puls];
                end
        end
    else % normal behaviour
        if RF.pulseshift == 0 && mod(puls,RF.npe) == 0 % not sweep and first pulse in 2D k-space
            sliceshift = sliceshift + RF.thk + RF.slicegap;
            firstpulse = [firstpulse; puls];
        end
    end
    
%     xx =  zzabs + (puls - 1).*RF.pulseshift + sliceshift + motion_resp(puls) + (puls - 1).*motion.flow_per_pulse; % where the pulse IS
        xx =  zzabs + (puls - 1).*RF.pulseshift + sliceshift + motion_resp(puls) - (puls - 1).*motion.flow_per_pulse; % where the pulse IS; flow shift is -ve

    zq = find((tissue.vec >= xx(1)) & (tissue.vec <  (zzabs(end) + xx(end)))); % index of these locations in tissue vector
    
    flipvec = interp1(xx,RF.profile,tissue.vec(zq),'linear');
    flipmat(puls,zq) = flipvec;
    dat.offset(puls) = xx(1);
    
end
figure();imagesc(tissue.vec.*1000-RF.range,1:RF.npulses,rad2deg(flipmat));

flipmat(isnan(flipmat)==1) = 0; % remove nans

% Include catalysation pulses
if ~isempty(RF.catalysation)
    for rr = 1:length(RF.catalysation)
        for ff = 1:length(firstpulse)
            fliploc = firstpulse(ff)+(rr-1);
            if fliploc > size(flipmat,1)
                continue;
            end
            v = flipmat(fliploc,:);
            v = (v - min(v(:))) / (max(v(:)) - min(v(:)));
            flipmat(fliploc,:) = v*deg2rad(RF.catalysation(rr));
        end
    end
end

%% EPG
phi = RF_phase_cycle(length(flipmat(:,1)), RF.seq); % phase cycling scheme

if offload == 1
    SS.flipmat = flipmat;
    SS.phi = phi;
    SS.RF = RF;
    SS.tissue = tissue;
    s0_RF = send2remote('EPG_sim_offload',SS,'ssh','ssh_beastie01.mat');
    delete('temp_struct.mat')
else
    parfor zz = 1:size(flipmat,2)
        s0_RF(:,zz) = EPG_GRE(flipmat(:,zz),phi,RF.TR,tissue.T1,tissue.T2);
    end
end

%% convert to scanner co-ordinates- space in which signals are measured
% tissue.vec = linspace(tissue.min,tissue.length,RF.npulses.*tissue_multiplier);  % redeclare tissue.vec to remove flow extension if it exists

coverage_min = -RF.range*1e-3;
coverage_max = ((RF.thk + RF.slicegap) * RF.nslice) + (RF.pulseshift.*RF.npulses) + RF.range*1e-3;

tissue.scanner_space = linspace(coverage_min, coverage_max, tissue_resolution); % scanner space imaging volume

sliceshift = 0;
s0 = zeros([RF.npulses,length(tissue.vec)]);
for puls = 1:RF.npulses

    xx =  tissue.vec + sliceshift - motion_resp(puls) + (puls - 1).*motion.flow_per_pulse - (RF.range*1e-3);
    zq = find((tissue.scanner_space >= xx(1)) & (tissue.scanner_space <  xx(end))); % index of these locations in tissue vector
    flipvec = interp1(xx,s0_RF(puls,:),tissue.scanner_space(zq),'linear');
    
    s0(puls,zq) = flipvec;

    if RF.swp == 0
        xx_pr =  tissue.vec - (1e-3 * RF.range) - ((RF.thk + RF.slicegap) * floor(puls/RF.npe)) - sliceshift - motion_resp(puls) + (puls - 1).*motion.flow_per_pulse; % where the pulse IS
    else
        xx_pr =  tissue.vec - (1e-3 * RF.range) - (puls - 1).*RF.pulseshift - sliceshift - motion_resp(puls) + (puls - 1).*motion.flow_per_pulse; % where the pulse IS
    end
    
    zq_pr = find((tissue.vec >= xx_pr(1)) & (tissue.vec <  xx_pr(end))); % index of these locations in tissue vector
    qq = linspace(tissue.vec(zq_pr(1)),tissue.vec(zq_pr(end)),1000);
    
    dat.profile(1,:,puls) = qq; % z location
    dat.profile(2,:,puls) = interp1(xx_pr,s0_RF(puls,:),qq,'linear'); % amplitude
    
    dat.profile_common(1,:,puls) = linspace(-RF.range*1e-3, RF.range*1e-3, 1000);
    dat.profile_common(2,:,puls) = interp1(xx_pr,s0_RF(puls,:),dat.profile_common(1,:,puls),'linear'); % amplitude
    
end

figure();imagesc(tissue.scanner_space.*1e3,1:RF.npulses,abs(s0));

s0(isnan(s0)==1) = 0; % remove nans

%% Bring results into dat
dat.s0 = s0; % signal in scanner space
% dat.s0_RF = s0_RF; % signal in RF space - useful for debugging
dat.flipmat = flipmat;
dat.RF = RF;
dat.motion = motion;
dat.tissue = tissue;
