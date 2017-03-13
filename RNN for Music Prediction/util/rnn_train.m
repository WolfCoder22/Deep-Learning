function [net, stats] = rnn_train(net, imdb, getBatch, varargin)
%RNN_TRAIN modifies CNN_TRAIN for a recurrent net. RNN_TRAIN is an adaptation
% of the CNN_TRAIN example function written to work wth rnns. Some of the
% functionality of CNN_TRAIN has been stripped away, especally with respect
% to GPU processing.
%
% For set of each sequences in a batch, the folowing actions occur when trainig:
%  1. Initialize layer states for the forward pass
%  2. Perform a full state-saving forward propagation for all
%  steps, where the results of each step are saved in a cell array
%  3. Initialize layer states for the backward pass
%  4. Perform backward propagation,
%  utilizing the states previously saved in the cell array
% When evaluating, only steps 1 and 2 are performed.
%
% With T ndicating the number of time steps, C the number of classes, and N the 
% batch size, getBatch is expected to return [seq_x, seq_y], where the
% dimensions are [1, T, C, N] and [1, T, 1, N], respectively.
% This function handles the following three custom layer types specially
% (identfied by the 'subtype' field of the layer):
%  - fully_connected
%  - recurrent_tanh
%  - recurrent_lstm
% The implementatons of these should be provided by the student. The
% recurrent_* layers utlize the following state-management functions, which
% have already been written:
%  - rnn_init_forward_states
%  - rnn_int_backward_states
%  - rnn_gather_gradients
% Please see the documentation for these files for more information.


opts.expDir = fullfile('data','exp') ;
opts.continue = true ;
opts.batchSize = 256 ;
opts.numSubBatches = 1 ;
opts.train = [] ;
opts.val = [] ;
opts.gpus = [] ;
opts.prefetch = false ;
opts.numEpochs = 300 ;
opts.learningRate = 0.001 ;
opts.weightDecay = 0.0005 ;
opts.momentum = 0.9 ;
opts.saveMomentum = false ;
opts.nesterovUpdate = false ;
opts.randomSeed = 0 ;
opts.profile = false ;

opts.conserveMemory = true ;
opts.backPropDepth = +inf ;
opts.errorFunction = 'multiclass' ;
opts.errorLabels = {} ;
opts.plotDiagnostics = false ;
opts.plotStatistics = true;
opts.dataDir = '' ;
opts = vl_argparse(opts, varargin) ;

if ~exist(opts.expDir, 'dir'), mkdir(opts.expDir) ; end
if isempty(opts.train), opts.train = find(imdb.images.set==1) ; end
if isempty(opts.val), opts.val = find(imdb.images.set==2) ; end
if isnan(opts.train), opts.train = [] ; end
if isnan(opts.val), opts.val = [] ; end

% -------------------------------------------------------------------------
%                                                            Initialization
% -------------------------------------------------------------------------

net = vl_simplenn_tidy(net); % fill in some eventually missing values
net.layers{end-1}.precious = 1; % do not remove predictions, used for error

evaluateMode = isempty(opts.train) ;
if ~evaluateMode
  for i=1:numel(net.layers)
    J = numel(net.layers{i}.weights) ;
    if ~isfield(net.layers{i}, 'learningRate')
      net.layers{i}.learningRate = ones(1, J) ;
    end
    if ~isfield(net.layers{i}, 'weightDecay')
      net.layers{i}.weightDecay = ones(1, J) ;
    end
  end
end

% setup error calculation function
hasError = true ;
if isstr(opts.errorFunction)
  switch opts.errorFunction
    case 'none'
      opts.errorFunction = @error_none ;
      hasError = false ;
    case 'multiclass'
      opts.errorFunction = @error_multiclass ;
      if isempty(opts.errorLabels), opts.errorLabels = {'top1err', 'top5err'} ; end
    case 'binary'
      opts.errorFunction = @error_binary ;
      if isempty(opts.errorLabels), opts.errorLabels = {'binerr'} ; end
    otherwise
      error('Unknown error function ''%s''.', opts.errorFunction) ;
  end
end

state.getBatch = getBatch ;
stats = [] ;

% -------------------------------------------------------------------------
%                                                        Train and validate
% -------------------------------------------------------------------------

modelPath = @(ep) fullfile(opts.expDir, sprintf('net-epoch-%d.mat', ep));
modelFigPath = fullfile(opts.expDir, 'net-train.pdf') ;

start = opts.continue * findLastCheckpoint(opts.expDir) ;
if start >= 1
  fprintf('%s: resuming by loading epoch %d\n', mfilename, start) ;
  [net, state, stats] = loadState(modelPath(start)) ;
else
  state = [] ;
end

for epoch=start+1:opts.numEpochs

  % Set the random seed based on the epoch and opts.randomSeed.
  % This is important for reproducibility, including when training
  % is restarted from a checkpoint.

  rng(epoch + opts.randomSeed) ;

  % Train for one epoch.
  params = opts ;
  params.epoch = epoch ;
  params.learningRate = opts.learningRate(min(epoch, numel(opts.learningRate))) ;
  params.train = opts.train(randperm(numel(opts.train))) ; % shuffle
  params.val = opts.val(randperm(numel(opts.val))) ;
  params.imdb = imdb ;
  params.getBatch = getBatch ;  

  if numel(params.gpus) <= 1
    [net, state] = processEpoch(net, state, params, 'train') ;
    [net, state] = processEpoch(net, state, params, 'val') ;
    if ~evaluateMode
      saveState(modelPath(epoch), net, state) ;
    end
    lastStats = state.stats ;
  else
    spmd
      [net, state] = processEpoch(net, state, params, 'train') ;
      [net, state] = processEpoch(net, state, params, 'val') ;
      if labindex == 1 && ~evaluateMode
        saveState(modelPath(epoch), net, state) ;
      end
      lastStats = state.stats ;
    end
    lastStats = accumulateStats(lastStats) ;
  end

  stats.train(epoch) = lastStats.train ;
  stats.val(epoch) = lastStats.val ;
  clear lastStats ;
  saveStats(modelPath(epoch), stats) ;

  if params.plotStatistics
    switchFigure(1) ; clf ;
    plots = setdiff(...
      cat(2,...
      fieldnames(stats.train)', ...
      fieldnames(stats.val)'), {'num', 'time'}) ;
    for p = plots
      p = char(p) ;
      values = zeros(0, epoch) ;
      leg = {} ;
      for f = {'train', 'val'}
        f = char(f) ;
        if isfield(stats.(f), p)
          tmp = [stats.(f).(p)] ;
          values(end+1,:) = tmp(1,:)' ;
          leg{end+1} = f ;
        end
      end
      subplot(1,numel(plots),find(strcmp(p,plots))) ;
      plot(1:epoch, values','o-') ;
      xlabel('epoch') ;
      title(p) ;
      legend(leg{:}) ;
      grid on ;
    end
    drawnow ;
    print(1, modelFigPath, '-dpdf') ;
  end
end


% -------------------------------------------------------------------------
function err = error_multiclass(params, labels, res)
% -------------------------------------------------------------------------
predictions = gather(res(end-1).x) ;
[~,predictions] = sort(predictions, 3, 'descend') ;

% be resilient to badly formatted labels
if numel(labels) == size(predictions, 4)
  labels = reshape(labels,1,1,1,[]) ;
end

% skip null labels
mass = labels(:,:,1,:) > 0 ;
if size(labels,3) == 2
  % if there is a second channel in labels, used it as weights
  mass = mass .* labels(:,:,2,:) ;
  labels(:,:,2,:) = [] ;
end

m = min(5, size(predictions,3)) ;

error = ~bsxfun(@eq, predictions, labels) ;
err(1,1) = sum(sum(sum(mass .* error(:,:,1,:)))) ;
err(2,1) = sum(sum(sum(mass .* min(error(:,:,1:m,:),[],3)))) ;

% -------------------------------------------------------------------------
function err = error_binary(params, labels, res)
% -------------------------------------------------------------------------
predictions = gather(res(end-1).x) ;
error = bsxfun(@times, predictions, labels) < 0 ;
err = sum(error(:)) ;

% -------------------------------------------------------------------------
function err = error_none(params, labels, res)
% -------------------------------------------------------------------------
err = zeros(0,1) ;

% -------------------------------------------------------------------------
function [net, state] = processEpoch(net, state, params, mode)
% -------------------------------------------------------------------------
% Note that net is not strictly needed as an output argument as net
% is a handle class. However, this fixes some aliasing issue in the
% spmd caller.

parserv = [];

% initialize with momentum 0
if isempty(state) || isempty(state.momentum)
  for i = 1:numel(net.layers)
    for j = 1:numel(net.layers{i}.weights)
      state.momentum{i}{j} = 0 ;
    end
  end
end

% profile
if params.profile
  profile clear ;
  profile on ;
end

num = 0 ;
epoch = params.epoch ;
subset = params.(mode) ;
adjustTime = 0 ;

stats.num = 0 ; % return something even if subset = []
stats.time = 0 ;
error = [] ;


start = tic ;
for t=1:params.batchSize:numel(subset)
  fprintf('%s: epoch %02d: %3d/%3d:', mode, epoch, ...
          fix((t-1)/params.batchSize)+1, ceil(numel(subset)/params.batchSize)) ;
  batchSize = min(params.batchSize, numel(subset) - t + 1) ;

  for s=1:params.numSubBatches
    % get this image batch and prefetch the next
    batchStart = t + (labindex-1) + (s-1) * numlabs ;
    batchEnd = min(t+params.batchSize-1, numel(subset)) ;
    batch = subset(batchStart : params.numSubBatches * numlabs : batchEnd) ;
    if numel(batch) == 0, continue ; end
    
    [seq_x, seq_labels] = params.getBatch(params.imdb, batch) ;
    % normalize by number of valid instances. assumes that the third dimenson of
    % seq_labels has a second eleent representing trianing instance weight.
    num = num + numel(find(seq_labels(:,:,2,:)~=0));
    total_seq_len = size(seq_x,2);
    if ~total_seq_len
      continue;
    end
    if strcmp(mode, 'train')
      seq_error = 0;
      % forward, with state saving
      res_ary = cell(1, total_seq_len);
      res_ary{1} = rnn_init_forward_states(net, batchSize);
      for i = 1:total_seq_len
        if i > 1
          res_ary{i} = rnn_init_forward_states(net, batchSize, res_ary{i-1});
        end
        x = seq_x(:,i,:,:);
        labels = seq_labels(:,i,:,:);
        net.layers{end}.class = labels;
        res_ary{i} = vl_simplenn(net, x, [], res_ary{i});
        seq_error = seq_error + res_ary{i}(end).x;
        error = sum([error, ...
          [...
          sum(res_ary{i}(end).x); ...
          reshape(params.errorFunction(params, labels, res_ary{i}),[],1)] ...
          ],2);
      end

      % backward
      for i = total_seq_len:-1:1
        if i == total_seq_len
          res_ary{i} = rnn_init_backward_states(net, batchSize, res_ary{i});
        else
          res_ary{i} = rnn_init_backward_states(net, batchSize, res_ary{i}, ...
            res_ary{i+1});
        end
        labels = seq_labels(:,i,:,:);
        net.layers{end}.class = labels;
        res_ary{i} = vl_simplenn(net, [], 1, res_ary{i}, 'SkipForward', true);
      end   
      res = rnn_gather_gradients(net, res_ary);
      % accumulate gradient
      [net, res, state] = accumulateGradients(net, res, state, params, ...
        batchSize, parserv) ;
    else
      res = rnn_init_forward_states(net, batchSize);
      for i = 1:total_seq_len
        x = seq_x(:,i,:,:);
        labels = seq_labels(:,i,:,:);
        net.layers{end}.class = labels;
        res = vl_simplenn(net, x, [], res, 'Mode', 'test');
        error = sum([error, ...
          [sum(res(end).x); ...
          reshape(params.errorFunction(params, labels, res),[],1)] ...
          ],2);
      end
    end
  end
  
  % Get statistics.
  time = toc(start) + adjustTime ;
  batchTime = time - stats.time ;
  stats = extractStats(net, params, error / num) ;
  stats.num = num ;
  stats.time = time ;
  currentSpeed = batchSize / batchTime ;
  averageSpeed = (t + batchSize - 1) / time ;
  if t == 3*params.batchSize + 1
    % compensate for the first three iterations, which are outliers
    adjustTime = 4*batchTime - time ;
    stats.time = time + adjustTime ;
  end

  fprintf(' %.1f (%.1f) Hz', averageSpeed, currentSpeed) ;
  for f = setdiff(fieldnames(stats)', {'num', 'time'})
    f = char(f) ;
    fprintf(' %s: %.3f', f, stats.(f)) ;
  end
  fprintf('\n') ;

  % collect diagnostic statistics
  if strcmp(mode, 'train') && params.plotDiagnostics
    switchFigure(2) ; clf ;
    diagn = [res.stats] ;
    diagnvar = horzcat(diagn.variation) ;
    diagnpow = horzcat(diagn.power) ;
    subplot(2,2,1) ; barh(diagnvar) ;
    set(gca,'TickLabelInterpreter', 'none', ...
      'YTick', 1:numel(diagnvar), ...
      'YTickLabel',horzcat(diagn.label), ...
      'YDir', 'reverse', ...
      'XScale', 'log', ...
      'XLim', [1e-5 1], ...
      'XTick', 10.^(-5:1)) ;
    grid on ;
    subplot(2,2,2) ; barh(sqrt(diagnpow)) ;
    set(gca,'TickLabelInterpreter', 'none', ...
      'YTick', 1:numel(diagnpow), ...
      'YTickLabel',{diagn.powerLabel}, ...
      'YDir', 'reverse', ...
      'XScale', 'log', ...
      'XLim', [1e-5 1e5], ...
      'XTick', 10.^(-5:5)) ;
    grid on ;
    subplot(2,2,3); plot(squeeze(res(end-1).x)) ;
    drawnow ;
  end
end

% Save back to state.
% stats = averageStats(all_stats);
state.stats.(mode) = stats ;
if params.profile
  if numGpus <= 1
    state.prof.(mode) = profile('info') ;
    profile off ;
  else
    state.prof.(mode) = mpiprofile('info');
    mpiprofile off ;
  end
end
if ~params.saveMomentum
  state.momentum = [] ;
else
  for i = 1:numel(state.momentum)
    for j = 1:numel(state.momentum{i})
      state.momentum{i}{j} = gather(state.momentum{i}{j}) ;
    end
  end
end

function stats = averageStats(all_stats)
stats = struct();
f = fieldnames(all_stats{1});
for i = 1:numel(f)
  stats.(f{i}) = mean(cellfun(@(x) x.(f{i}), all_stats));
end

% -------------------------------------------------------------------------
function [net, res, state] = accumulateGradients(net, res, state, params, ...
  batchSize, parserv)
% -------------------------------------------------------------------------
numGpus = numel(params.gpus) ;
otherGpus = setdiff(1:numGpus, labindex) ;

for l=numel(net.layers):-1:1
  for j=numel(res(l).dzdw):-1:1

    if ~isempty(parserv)
      tag = sprintf('l%d_%d',l,j) ;
      parDer = parserv.pull(tag) ;
    else
      parDer = res(l).dzdw{j}  ;
    end

    if j == 3 && strcmp(net.layers{l}.type, 'bnorm')
      % special case for learning bnorm moments
      thisLR = net.layers{l}.learningRate(j) ;
      net.layers{l}.weights{j} = vl_taccum(...
        1 - thisLR, ...
        net.layers{l}.weights{j}, ...
        thisLR / batchSize, ...
        parDer) ;
    else
      % Standard gradient training.
      thisDecay = params.weightDecay * net.layers{l}.weightDecay(j) ;
      thisLR = params.learningRate * net.layers{l}.learningRate(j) ;

      if thisLR>0 || thisDecay>0
        % Normalize gradient and incorporate weight decay.
        parDer = vl_taccum(1/batchSize, parDer, ...
                           thisDecay, net.layers{l}.weights{j}) ;

        % Update momentum.
        state.momentum{l}{j} = vl_taccum(...
          params.momentum, state.momentum{l}{j}, ...
          -1, parDer) ;

        % Nesterov update (aka one step ahead).
        if params.nesterovUpdate
          delta = vl_taccum(...
            params.momentum, state.momentum{l}{j}, ...
            -1, parDer) ;
        else
          delta = state.momentum{l}{j} ;
        end

        % Update parameters.
        net.layers{l}.weights{j} = vl_taccum(...
          1, net.layers{l}.weights{j}, ...
          thisLR, delta) ;
      end
    end

    % if requested, collect some useful stats for debugging
    if params.plotDiagnostics
      variation = [] ;
      label = '' ;
      switch net.layers{l}.type
        case {'conv','convt'}
          variation = thisLR * mean(abs(state.momentum{l}{j}(:))) ;
          power = mean(res(l+1).x(:).^2) ;
          if j == 1 % fiters
            base = mean(net.layers{l}.weights{j}(:).^2) ;
            label = 'filters' ;
          else % biases
            base = sqrt(power) ;%mean(abs(res(l+1).x(:))) ;
            label = 'biases' ;
          end
          variation = variation / base ;
          label = sprintf('%s_%s', net.layers{l}.name, label) ;
      end
      res(l).stats.variation(j) = variation ;
      res(l).stats.power = power ;
      res(l).stats.powerLabel = net.layers{l}.name ;
      res(l).stats.label{j} = label ;
    end
  end
end

% -------------------------------------------------------------------------
function stats = accumulateStats(stats_)
% -------------------------------------------------------------------------

for s = {'train', 'val'}
  s = char(s) ;
  total = 0 ;

  % initialize stats stucture with same fields and same order as
  % stats_{1}
  stats__ = stats_{1} ;
  names = fieldnames(stats__.(s))' ;
  values = zeros(1, numel(names)) ;
  fields = cat(1, names, num2cell(values)) ;
  stats.(s) = struct(fields{:}) ;

  for g = 1:numel(stats_)
    stats__ = stats_{g} ;
    num__ = stats__.(s).num ;
    total = total + num__ ;

    for f = setdiff(fieldnames(stats__.(s))', 'num')
      f = char(f) ;
      stats.(s).(f) = stats.(s).(f) + stats__.(s).(f) * num__ ;

      if g == numel(stats_)
        stats.(s).(f) = stats.(s).(f) / total ;
      end
    end
  end
  stats.(s).num = total ;
end

% -------------------------------------------------------------------------
function stats = extractStats(net, params, errors)
% -------------------------------------------------------------------------
stats.loss = errors(1) ;
for i = 1:numel(params.errorLabels)
  stats.(params.errorLabels{i}) = errors(i+1) ;
end

% -------------------------------------------------------------------------
function saveState(fileName, net, state)
% -------------------------------------------------------------------------
save(fileName, 'net', 'state') ;

% -------------------------------------------------------------------------
function saveStats(fileName, stats)
% -------------------------------------------------------------------------
if exist(fileName)
  save(fileName, 'stats', '-append') ;
else
  save(fileName, 'stats') ;
end

% -------------------------------------------------------------------------
function [net, state, stats] = loadState(fileName)
% -------------------------------------------------------------------------
load(fileName, 'net', 'state', 'stats') ;
net = vl_simplenn_tidy(net) ;
if isempty(whos('stats'))
  error('Epoch ''%s'' was only partially saved. Delete this file and try again.', ...
        fileName) ;
end

% -------------------------------------------------------------------------
function epoch = findLastCheckpoint(modelDir)
% -------------------------------------------------------------------------
list = dir(fullfile(modelDir, 'net-epoch-*.mat')) ;
tokens = regexp({list.name}, 'net-epoch-([\d]+).mat', 'tokens') ;
epoch = cellfun(@(x) sscanf(x{1}{1}, '%d'), tokens) ;
epoch = max([epoch 0]) ;

% -------------------------------------------------------------------------
function switchFigure(n)
% -------------------------------------------------------------------------
if get(0,'CurrentFigure') ~= n
  try
    set(0,'CurrentFigure',n) ;
  catch
    figure(n) ;
  end
end

