import { useState, useEffect } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { ArrowLeft, CheckCircle2, Clock, Terminal } from 'lucide-react';

interface RunProgressProps {
  runName: string;
  technology: string;
  inputType?: string;
  seqApproach: string;
  sampleType: string;
  runScope: string;
  valenciaClass?: string;
  qualityThreshold: number;
  minReadLength: number;
  trimAdapter: boolean;
  demultiplex: boolean;
  barcodingKit?: string;
  ligationKit?: string;
  outputDir: string;
  outputTypes: Record<string, boolean>;
  readType: 'short' | 'long';
  humanReadDepletion?: boolean;
}

export function RunProgressPage() {
  const location = useLocation();
  const navigate = useNavigate();
  const params = location.state as RunProgressProps;
  
  const [logs, setLogs] = useState<Array<{ time: string; message: string; type: 'info' | 'success' | 'warning' }>>([]);
  const [currentStep, setCurrentStep] = useState(0);
  const [isComplete, setIsComplete] = useState(false);

  // Redirect if no params
  useEffect(() => {
    if (!params) {
      navigate('/');
    }
  }, [params, navigate]);

  // Simulate log generation
  useEffect(() => {
    if (!params) return;

    const steps = [
      { delay: 500, message: 'Initializing pipeline...', type: 'info' as const },
      { delay: 1000, message: `Loading input data from ${params.outputDir}`, type: 'info' as const },
      { delay: 1500, message: `Technology: ${params.technology}`, type: 'info' as const },
      { delay: 2000, message: `Quality threshold set to ${params.qualityThreshold}`, type: 'info' as const },
      { delay: 2500, message: `Minimum read length: ${params.minReadLength} bp`, type: 'info' as const },
      { delay: 3000, message: 'Starting quality control...', type: 'info' as const },
      { delay: 4000, message: 'QC checks passed successfully', type: 'success' as const },
      ...(params.trimAdapter ? [{ delay: 4500, message: 'Trimming adapter sequences...', type: 'info' as const }] : []),
      ...(params.trimAdapter ? [{ delay: 5500, message: 'Adapter trimming complete', type: 'success' as const }] : []),
      ...(params.demultiplex ? [{ delay: 6000, message: 'Demultiplexing samples...', type: 'info' as const }] : []),
      ...(params.demultiplex ? [{ delay: 7000, message: 'Demultiplexing complete', type: 'success' as const }] : []),
      ...(params.humanReadDepletion && params.seqApproach === 'metagenomics' 
        ? [
            { delay: params.demultiplex ? 7500 : 6000, message: 'Depleting human reads...', type: 'info' as const },
            { delay: params.demultiplex ? 8500 : 7000, message: 'Human read depletion complete', type: 'success' as const }
          ] 
        : []
      ),
      { delay: params.humanReadDepletion && params.seqApproach === 'metagenomics' 
          ? (params.demultiplex ? 9000 : 7500) 
          : (params.demultiplex ? 7500 : 6000), 
        message: `Processing ${params.seqApproach} data...`, 
        type: 'info' as const 
      },
      { delay: params.humanReadDepletion && params.seqApproach === 'metagenomics' 
          ? (params.demultiplex ? 10500 : 9000) 
          : (params.demultiplex ? 9000 : 7500), 
        message: 'Taxonomic classification in progress...', 
        type: 'info' as const 
      },
      { delay: params.humanReadDepletion && params.seqApproach === 'metagenomics' 
          ? (params.demultiplex ? 12500 : 11000) 
          : (params.demultiplex ? 11000 : 9500), 
        message: 'Classification complete', 
        type: 'success' as const 
      },
      ...(params.valenciaClass === 'yes' && params.sampleType === 'vaginal' 
        ? [
            { delay: params.humanReadDepletion && params.seqApproach === 'metagenomics'
                ? (params.demultiplex ? 13000 : 11500)
                : (params.demultiplex ? 11500 : 10000), 
              message: 'Running VALENCIA classification...', 
              type: 'info' as const 
            },
            { delay: params.humanReadDepletion && params.seqApproach === 'metagenomics'
                ? (params.demultiplex ? 14500 : 13000)
                : (params.demultiplex ? 13000 : 11500), 
              message: 'VALENCIA classification complete', 
              type: 'success' as const 
            }
          ] 
        : []
      ),
      { delay: params.valenciaClass === 'yes' && params.sampleType === 'vaginal' 
          ? (params.humanReadDepletion && params.seqApproach === 'metagenomics'
              ? (params.demultiplex ? 15000 : 13500)
              : (params.demultiplex ? 13500 : 12000))
          : (params.humanReadDepletion && params.seqApproach === 'metagenomics'
              ? (params.demultiplex ? 13000 : 11500)
              : (params.demultiplex ? 11500 : 10000)), 
        message: 'Generating output files...', 
        type: 'info' as const 
      },
      ...(Object.entries(params.outputTypes)
        .filter(([_, enabled]) => enabled)
        .map(([type, _], index) => ({
          delay: (params.valenciaClass === 'yes' && params.sampleType === 'vaginal' 
            ? (params.humanReadDepletion && params.seqApproach === 'metagenomics'
                ? (params.demultiplex ? 15500 : 14000)
                : (params.demultiplex ? 14000 : 12500))
            : (params.humanReadDepletion && params.seqApproach === 'metagenomics'
                ? (params.demultiplex ? 13500 : 12000)
                : (params.demultiplex ? 12000 : 10500))) + (index * 500),
          message: `Generated ${type} output`,
          type: 'success' as const
        }))
      ),
      { 
        delay: (params.valenciaClass === 'yes' && params.sampleType === 'vaginal' 
          ? (params.humanReadDepletion && params.seqApproach === 'metagenomics'
              ? (params.demultiplex ? 17000 : 15500)
              : (params.demultiplex ? 15500 : 14000))
          : (params.humanReadDepletion && params.seqApproach === 'metagenomics'
              ? (params.demultiplex ? 15000 : 13500)
              : (params.demultiplex ? 13500 : 12000))) + 
          (Object.values(params.outputTypes).filter(Boolean).length * 500),
        message: '✓ Pipeline completed successfully!', 
        type: 'success' as const 
      },
    ];

    steps.forEach((step, index) => {
      setTimeout(() => {
        const now = new Date();
        const timeStr = `${now.getHours().toString().padStart(2, '0')}:${now.getMinutes().toString().padStart(2, '0')}:${now.getSeconds().toString().padStart(2, '0')}`;
        
        setLogs(prev => [...prev, { time: timeStr, message: step.message, type: step.type }]);
        setCurrentStep(index + 1);
        
        if (index === steps.length - 1) {
          setIsComplete(true);
        }
      }, step.delay);
    });
  }, [params]);

  if (!params) {
    return null;
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-gray-900">{params.runName || 'Pipeline Run'}</h1>
          <p className="text-gray-600">{params.readType === 'short' ? 'Short Read' : 'Long Read'} Sequencing Pipeline</p>
        </div>
        {isComplete && (
          <button
            onClick={() => navigate(params.readType === 'short' ? '/short-read' : '/long-read')}
            className="flex items-center gap-2 px-4 py-2 text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50 transition-colors"
          >
            <ArrowLeft className="w-4 h-4" />
            Back to Configuration
          </button>
        )}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-4 gap-6">
        {/* Run Parameters Panel */}
        <div className="lg:col-span-1 space-y-4">
          <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-4">
            <h2 className="text-gray-900 mb-4 flex items-center gap-2">
              {isComplete ? (
                <CheckCircle2 className="w-5 h-5 text-green-600" />
              ) : (
                <Clock className="w-5 h-5 text-blue-600 animate-pulse" />
              )}
              Run Parameters
            </h2>
            
            <div className="space-y-3 text-sm">
              <div>
                <p className="text-gray-500">Technology</p>
                <p className="text-gray-900 capitalize">{params.technology}</p>
              </div>
              
              {params.inputType && (
                <div>
                  <p className="text-gray-500">Input Type</p>
                  <p className="text-gray-900 uppercase">{params.inputType}</p>
                </div>
              )}
              
              <div>
                <p className="text-gray-500">Approach</p>
                <p className="text-gray-900">{params.seqApproach === '16S' ? '16S rRNA' : 'Metagenomics'}</p>
              </div>
              
              <div>
                <p className="text-gray-500">Sample Type</p>
                <p className="text-gray-900 capitalize">{params.sampleType}</p>
              </div>
              
              <div>
                <p className="text-gray-500">Quality Threshold</p>
                <p className="text-gray-900">{params.qualityThreshold}</p>
              </div>
              
              <div>
                <p className="text-gray-500">Min Read Length</p>
                <p className="text-gray-900">{params.minReadLength} bp</p>
              </div>
              
              <div>
                <p className="text-gray-500">Adapter Trimming</p>
                <p className="text-gray-900">{params.trimAdapter ? 'Yes' : 'No'}</p>
              </div>
              
              <div>
                <p className="text-gray-500">Demultiplexing</p>
                <p className="text-gray-900">{params.demultiplex ? 'Yes' : 'No'}</p>
              </div>
              
              {params.barcodingKit && (
                <div>
                  <p className="text-gray-500">Barcoding Kit</p>
                  <p className="text-gray-900 font-mono text-xs">{params.barcodingKit}</p>
                </div>
              )}
              
              {params.ligationKit && (
                <div>
                  <p className="text-gray-500">Ligation Kit</p>
                  <p className="text-gray-900 font-mono text-xs">{params.ligationKit}</p>
                </div>
              )}
              
              {params.valenciaClass === 'yes' && params.sampleType === 'vaginal' && (
                <div>
                  <p className="text-gray-500">VALENCIA</p>
                  <p className="text-gray-900">Enabled</p>
                </div>
              )}
              
              {params.humanReadDepletion && params.seqApproach === 'metagenomics' && (
                <div>
                  <p className="text-gray-500">Human Read Depletion</p>
                  <p className="text-gray-900">Enabled</p>
                </div>
              )}
              
              <div>
                <p className="text-gray-500">Output Directory</p>
                <p className="text-gray-900 font-mono text-xs break-all">{params.outputDir}</p>
              </div>
            </div>
          </div>
        </div>

        {/* Logs Panel */}
        <div className="lg:col-span-3">
          <div className="bg-gray-900 rounded-lg shadow-sm border border-gray-700 p-6 h-[calc(100vh-300px)] flex flex-col">
            <div className="flex items-center gap-2 mb-4 text-gray-300">
              <Terminal className="w-5 h-5" />
              <h2 className="text-white">Pipeline Logs</h2>
              {!isComplete && (
                <div className="ml-auto flex items-center gap-2 text-sm">
                  <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
                  Running...
                </div>
              )}
              {isComplete && (
                <div className="ml-auto flex items-center gap-2 text-sm text-green-400">
                  <CheckCircle2 className="w-4 h-4" />
                  Complete
                </div>
              )}
            </div>
            
            <div className="flex-1 overflow-y-auto font-mono text-sm space-y-1 bg-black bg-opacity-30 rounded p-4">
              {logs.map((log, index) => (
                <div 
                  key={index} 
                  className={`flex gap-3 ${
                    log.type === 'success' 
                      ? 'text-green-400' 
                      : log.type === 'warning' 
                      ? 'text-yellow-400' 
                      : 'text-gray-300'
                  }`}
                >
                  <span className="text-gray-500">[{log.time}]</span>
                  <span>{log.message}</span>
                </div>
              ))}
              {!isComplete && logs.length > 0 && (
                <div className="flex gap-3 text-gray-400">
                  <span className="animate-pulse">_</span>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}