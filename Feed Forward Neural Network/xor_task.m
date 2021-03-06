% This is the main script for assignment-1 CS-78/178

% Seed the rabdom generator. (Do not remove.)
rng(1234);

% 2.1 - Create the database based on the problem
dataset_path= ('xor_dataset.mat');

% Create the OPTS struct below
opts= struct('mean_subtration', false, 'normalization', false);

% Create the database by calling the create_database function below
database_xor= create_database(dataset_path, opts);


% Define the model you will be training below by specifying the struct
% 'netspec_opts' as described in the assignment handout.
hU= 3;
nL= {'tanH'};
iF=2;
lF= 'softmaxlog';
foS= 2;

netops= struct('hidden_units', hU, 'non_linearity', nL, 'input_features',iF, 'loss_function',lF, 'final_output_size', foS);

% Define the training policy below by specifying the struct train_opts as
% described in the assignment handout.
m=.9;
nE=25;
lR=ones(1, nE)*.5;
bS=4;
wD= 0;

train_opts=struct('numEpochs', nE, 'learningRate', lR, 'momentum', m, 'batchSize', bS, 'weightDecay', wD, 'continue', false);

% Create a network by calling your function create_dagnn_net
net = create_dagnn_net(netops, train_opts);

% Specify the model_opts struct below to define where to store your trained
% model, the type of model, and that you will not be using gpus for
% training.
expDir={'epochData/xor'};
train= struct('gpus', []);
model_opts= struct('expDir', expDir, 'train', train);

% Function  trains the network.
trainFn = @cnn_train_dag ;
getBatchFn = @(x,y) getBatch(x,y);
[net, info] = trainFn(net, database_xor, getBatchFn, ...
                      'expDir', model_opts.expDir, ...
                      net.meta.trainOpts, ...
                      model_opts.train) ;
