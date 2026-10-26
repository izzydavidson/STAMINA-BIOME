import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Play, Settings, FileText, Upload, X } from 'lucide-react';

export function ShortReadPage() {
  const navigate = useNavigate();
  const [technology, setTechnology] = useState('illumina');
  const [qualityThreshold, setQualityThreshold] = useState(20);
  const [minReadLength, setMinReadLength] = useState(50);
  const [trimAdapter, setTrimAdapter] = useState(true);
  const [demultiplex, setDemultiplex] = useState(false);
  const [primerSequence, setPrimerSequence] = useState('');
  const [barcodeSequence, setBarcodeSequence] = useState('');
  const [barcodingKit, setBarcodingKit] = useState('');
  const [seqApproach, setSeqApproach] = useState('16S');
  const [sampleType, setSampleType] = useState('vaginal');
  const [runName, setRunName] = useState('');
  const [outputDir, setOutputDir] = useState('/output/results');
  const [runScope, setRunScope] = useState('full');
  const [valenciaClass, setValenciaClass] = useState('yes');
  const [outputTypes, setOutputTypes] = useState({
    csv: true,
    piechart: false,
    heatmap: false,
    stackedbar: false,
    qualityReports: false,
  });
  const [running, setRunning] = useState(false);
  const [humanReadDepletion, setHumanReadDepletion] = useState(false);
  const [inputFiles, setInputFiles] = useState<File[]>([]);
  const [pairedEnd, setPairedEnd] = useState(false);
  const [dada2TruncF, setDada2TruncF] = useState('');
  const [dada2TruncR, setDada2TruncR] = useState('');

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>, fileType?: 'r1' | 'r2') => {
    const files = e.target.files;
    if (files) {
      const fileArray = Array.from(files);
      if (pairedEnd && fileType) {
        // Handle paired-end file selection
        setInputFiles(prev => {
          const newFiles = [...prev];
          if (fileType === 'r1') {
            newFiles[0] = fileArray[0];
          } else {
            newFiles[1] = fileArray[0];
          }
          return newFiles;
        });
      } else {
        setInputFiles(fileArray);
      }
    }
  };

  const removeFile = (index: number) => {
    setInputFiles(prev => prev.filter((_, i) => i !== index));
  };

  const handleRun = () => {
    setRunning(true);
    // Navigate to progress page with parameters
    setTimeout(() => {
      navigate('/run-progress', {
        state: {
          runName,
          technology: technology === 'illumina' ? 'Illumina' : technology === 'iontorrent' ? 'Ion Torrent' : 'BGI Platforms',
          seqApproach,
          sampleType,
          runScope,
          valenciaClass,
          qualityThreshold,
          minReadLength,
          trimAdapter,
          demultiplex,
          barcodingKit,
          outputDir,
          outputTypes,
          readType: 'short' as const,
          humanReadDepletion,
          inputFiles,
          pairedEnd,
          dada2TruncF,
          dada2TruncR,
        }
      });
    }, 500);
  };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-gray-900">Short Read Sequencing</h1>
        <p className="text-gray-600">Illumina, Ion Torrent, BGI platforms</p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Parameters Panel */}
        <div className="lg:col-span-2 space-y-6">
          {/* Input Configuration */}
          <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
            <div className="flex items-center gap-2 mb-6">
              <FileText className="w-5 h-5 text-gray-700" />
              <h2 className="text-gray-900">Input Configuration</h2>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
              <div>
                <label className="block text-gray-700 mb-2">Technology Used</label>
                <select
                  value={technology}
                  onChange={(e) => setTechnology(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                >
                  <option value="illumina">Illumina</option>
                  <option value="iontorrent">Ion Torrent</option>
                  <option value="bgi">BGI Platforms</option>
                </select>
              </div>

              <div>
                <label className="block text-gray-700 mb-2">Run Name/ID</label>
                <input
                  type="text"
                  value={runName}
                  onChange={(e) => setRunName(e.target.value)}
                  placeholder="e.g., SR_2026_001"
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                />
              </div>

              <div>
                <label className="block text-gray-700 mb-2">Output Directory</label>
                <input
                  type="text"
                  value={outputDir}
                  onChange={(e) => setOutputDir(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                />
              </div>
            </div>

            {/* File Input Section */}
            <div className="mt-6 pt-6 border-t border-gray-200">
              <div className="flex items-center gap-2 mb-4">
                <Upload className="w-5 h-5 text-gray-700" />
                <h3 className="text-gray-900">Input Files</h3>
              </div>

              <div className="space-y-4">
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="pairedEnd"
                    checked={pairedEnd}
                    onChange={(e) => {
                      setPairedEnd(e.target.checked);
                      setInputFiles([]);
                    }}
                    className="w-4 h-4 text-blue-600 rounded"
                  />
                  <label htmlFor="pairedEnd" className="text-gray-700">
                    Paired-End Reads
                  </label>
                </div>

                {pairedEnd ? (
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <label className="block text-gray-700 mb-2 text-sm">Forward Reads (R1)</label>
                      <label className="flex flex-col items-center px-4 py-6 bg-gray-50 border-2 border-gray-300 border-dashed rounded-md cursor-pointer hover:bg-gray-100 transition-colors">
                        <Upload className="w-6 h-6 text-gray-400 mb-2" />
                        <span className="text-sm text-gray-600">
                          {inputFiles[0] ? inputFiles[0].name : 'Select R1 file'}
                        </span>
                        <input
                          type="file"
                          onChange={(e) => handleFileChange(e, 'r1')}
                          accept=".fastq,.fq,.fastq.gz,.fq.gz"
                          className="hidden"
                        />
                      </label>
                    </div>

                    <div>
                      <label className="block text-gray-700 mb-2 text-sm">Reverse Reads (R2)</label>
                      <label className="flex flex-col items-center px-4 py-6 bg-gray-50 border-2 border-gray-300 border-dashed rounded-md cursor-pointer hover:bg-gray-100 transition-colors">
                        <Upload className="w-6 h-6 text-gray-400 mb-2" />
                        <span className="text-sm text-gray-600">
                          {inputFiles[1] ? inputFiles[1].name : 'Select R2 file'}
                        </span>
                        <input
                          type="file"
                          onChange={(e) => handleFileChange(e, 'r2')}
                          accept=".fastq,.fq,.fastq.gz,.fq.gz"
                          className="hidden"
                        />
                      </label>
                    </div>
                  </div>
                ) : (
                  <div>
                    <label className="block text-gray-700 mb-2 text-sm">FASTQ Files</label>
                    <label className="flex flex-col items-center px-4 py-8 bg-gray-50 border-2 border-gray-300 border-dashed rounded-md cursor-pointer hover:bg-gray-100 transition-colors">
                      <Upload className="w-8 h-8 text-gray-400 mb-2" />
                      <span className="text-sm text-gray-600 mb-1">Click to select files</span>
                      <span className="text-xs text-gray-500">or drag and drop</span>
                      <span className="text-xs text-gray-500 mt-2">FASTQ, FQ (.gz supported)</span>
                      <input
                        type="file"
                        onChange={(e) => handleFileChange(e)}
                        accept=".fastq,.fq,.fastq.gz,.fq.gz"
                        multiple
                        className="hidden"
                      />
                    </label>
                  </div>
                )}

                {inputFiles.length > 0 && !pairedEnd && (
                  <div className="space-y-2">
                    <p className="text-sm text-gray-700">Selected Files:</p>
                    {inputFiles.map((file, index) => (
                      <div key={index} className="flex items-center justify-between p-2 bg-blue-50 border border-blue-200 rounded-md">
                        <span className="text-sm text-gray-900 font-mono truncate">{file.name}</span>
                        <button
                          onClick={() => removeFile(index)}
                          className="text-red-600 hover:text-red-700 p-1"
                        >
                          <X className="w-4 h-4" />
                        </button>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
          </div>

          {/* Processing Parameters */}
          <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
            <div className="flex items-center gap-2 mb-6">
              <Settings className="w-5 h-5 text-gray-700" />
              <h2 className="text-gray-900">Processing Parameters</h2>
            </div>

            <div className="space-y-5">
              <div>
                <label className="block text-gray-700 mb-2">
                  Quality Score Threshold: <span className="text-blue-600">{qualityThreshold}</span>
                </label>
                <input
                  type="range"
                  min="0"
                  max="40"
                  value={qualityThreshold}
                  onChange={(e) => setQualityThreshold(Number(e.target.value))}
                  className="w-full"
                />
                <div className="flex justify-between text-xs text-gray-500 mt-1">
                  <span>0 (Low)</span>
                  <span>40 (High)</span>
                </div>
              </div>

              <div>
                <label className="block text-gray-700 mb-2">
                  Minimum Read Length: <span className="text-blue-600">{minReadLength} bp</span>
                </label>
                <input
                  type="range"
                  min="20"
                  max="300"
                  value={minReadLength}
                  onChange={(e) => setMinReadLength(Number(e.target.value))}
                  className="w-full"
                />
                <div className="flex justify-between text-xs text-gray-500 mt-1">
                  <span>20 bp</span>
                  <span>300 bp</span>
                </div>
              </div>

              <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="trimAdapter"
                    checked={trimAdapter}
                    onChange={(e) => setTrimAdapter(e.target.checked)}
                    className="w-4 h-4 text-blue-600 rounded"
                  />
                  <label htmlFor="trimAdapter" className="text-gray-700">
                    Trim Adapter Sequences
                  </label>
                </div>

                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="demultiplex"
                    checked={demultiplex}
                    onChange={(e) => setDemultiplex(e.target.checked)}
                    className="w-4 h-4 text-blue-600 rounded"
                  />
                  <label htmlFor="demultiplex" className="text-gray-700">
                    Demultiplex
                  </label>
                </div>
              </div>

              <div>
                <label className="block text-gray-700 mb-2">Primer Sequences</label>
                <textarea
                  value={primerSequence}
                  onChange={(e) => setPrimerSequence(e.target.value)}
                  placeholder="Enter primer sequences (one per line)"
                  rows={2}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900 font-mono text-sm"
                />
              </div>

              <div>
                <label className="block text-gray-700 mb-2">Barcode Sequences</label>
                <textarea
                  value={barcodeSequence}
                  onChange={(e) => setBarcodeSequence(e.target.value)}
                  placeholder="Enter barcode sequences (one per line)"
                  rows={2}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900 font-mono text-sm"
                />
              </div>

              <div>
                <label className="block text-gray-700 mb-2">Barcoding Kit (Optional)</label>
                <input
                  type="text"
                  value={barcodingKit}
                  onChange={(e) => setBarcodingKit(e.target.value)}
                  placeholder="e.g., EXP-NBD104"
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                />
              </div>
            </div>
          </div>

          {/* Analysis Configuration */}
          <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
            <h2 className="text-gray-900 mb-6">Analysis Configuration</h2>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
              <div>
                <label className="block text-gray-700 mb-2">Sequencing Approach</label>
                <select
                  value={seqApproach}
                  onChange={(e) => setSeqApproach(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                >
                  <option value="16S">16S rRNA Sequencing</option>
                  <option value="metagenomics">Metagenomics</option>
                </select>
              </div>

              <div>
                <label className="block text-gray-700 mb-2">Sample Type</label>
                <select
                  value={sampleType}
                  onChange={(e) => setSampleType(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                >
                  <option value="vaginal">Vaginal</option>
                  <option value="gut">Gut</option>
                  <option value="oral">Oral</option>
                  <option value="skin">Skin</option>
                </select>
              </div>

              <div>
                <label className="block text-gray-700 mb-2">Run Scope</label>
                <select
                  value={runScope}
                  onChange={(e) => setRunScope(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                >
                  <option value="qc">QC Only</option>
                  <option value="full">Full Pipeline</option>
                </select>
              </div>

              {sampleType === 'vaginal' && (
                <div>
                  <label className="block text-gray-700 mb-2">VALENCIA Classification</label>
                  <select
                    value={valenciaClass}
                    onChange={(e) => setValenciaClass(e.target.value)}
                    className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                  >
                    <option value="yes">Yes</option>
                    <option value="no">No</option>
                  </select>
                </div>
              )}
            </div>

            {/* DADA2 Truncation (only for 16S) */}
            {seqApproach === '16S' && (
              <div className="mt-5 pt-5 border-t border-gray-200">
                <h3 className="text-gray-900 mb-4">DADA2 Truncation Parameters</h3>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-gray-700 mb-2">
                      Forward Truncation Length (bp) <span className="text-red-600">*</span>
                    </label>
                    <input
                      type="number"
                      value={dada2TruncF}
                      onChange={(e) => setDada2TruncF(e.target.value)}
                      placeholder="e.g., 140"
                      required
                      className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                    />
                  </div>
                  <div>
                    <label className="block text-gray-700 mb-2">
                      Reverse Truncation Length (bp) <span className="text-red-600">*</span>
                    </label>
                    <input
                      type="number"
                      value={dada2TruncR}
                      onChange={(e) => setDada2TruncR(e.target.value)}
                      placeholder="e.g., 140"
                      required
                      className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                    />
                  </div>
                </div>
                <div className="mt-3 p-3 bg-yellow-50 border border-yellow-300 rounded-b-md text-sm text-yellow-900">
                  For 2×150 bp runs try 140/140, for 2×250 bp try 240/220, and for 2×300 bp try 280/220
                </div>
              </div>
            )}

            {seqApproach === 'metagenomics' && (
              <div className="mt-5">
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="humanReadDepletion"
                    checked={humanReadDepletion}
                    onChange={(e) => setHumanReadDepletion(e.target.checked)}
                    className="w-4 h-4 text-blue-600 rounded"
                  />
                  <label htmlFor="humanReadDepletion" className="text-gray-700">
                    Human Read Depletion
                  </label>
                </div>
                <p className="text-xs text-gray-500 mt-1 ml-6">
                  Remove human-derived sequences from the dataset
                </p>
              </div>
            )}

            {/* Output Types */}
            <div className="mt-6">
              <label className="block text-gray-700 mb-3">Output Types</label>
              <div className="grid grid-cols-2 gap-3">
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="csv"
                    checked={outputTypes.csv}
                    onChange={(e) => setOutputTypes({...outputTypes, csv: e.target.checked})}
                    className="w-4 h-4 text-blue-600 rounded"
                  />
                  <label htmlFor="csv" className="text-gray-700">Raw Data (.csv)</label>
                </div>
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="piechart"
                    checked={outputTypes.piechart}
                    onChange={(e) => setOutputTypes({...outputTypes, piechart: e.target.checked})}
                    className="w-4 h-4 text-blue-600 rounded"
                  />
                  <label htmlFor="piechart" className="text-gray-700">Pie Chart</label>
                </div>
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="heatmap"
                    checked={outputTypes.heatmap}
                    onChange={(e) => setOutputTypes({...outputTypes, heatmap: e.target.checked})}
                    className="w-4 h-4 text-blue-600 rounded"
                  />
                  <label htmlFor="heatmap" className="text-gray-700">Heatmap</label>
                </div>
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="stackedbar"
                    checked={outputTypes.stackedbar}
                    onChange={(e) => setOutputTypes({...outputTypes, stackedbar: e.target.checked})}
                    className="w-4 h-4 text-blue-600 rounded"
                  />
                  <label htmlFor="stackedbar" className="text-gray-700">Stacked Bar Chart</label>
                </div>
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="qualityReports"
                    checked={outputTypes.qualityReports}
                    onChange={(e) => setOutputTypes({...outputTypes, qualityReports: e.target.checked})}
                    className="w-4 h-4 text-blue-600 rounded"
                  />
                  <label htmlFor="qualityReports" className="text-gray-700">Quality Reports</label>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Run Panel */}
        <div className="lg:col-span-1">
          <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6 sticky top-6">
            <h2 className="text-gray-900 mb-6">Run Configuration</h2>

            <div className="space-y-4 mb-6">
              <div className="p-3 bg-gray-50 rounded-md border border-gray-200">
                <p className="text-sm text-gray-600">Technology</p>
                <p className="text-gray-900 capitalize">
                  {technology === 'illumina' && 'Illumina'}
                  {technology === 'iontorrent' && 'Ion Torrent'}
                  {technology === 'bgi' && 'BGI Platforms'}
                </p>
              </div>
              <div className="p-3 bg-gray-50 rounded-md border border-gray-200">
                <p className="text-sm text-gray-600">Approach</p>
                <p className="text-gray-900">{seqApproach === '16S' ? '16S rRNA' : 'Metagenomics'}</p>
              </div>
              <div className="p-3 bg-gray-50 rounded-md border border-gray-200">
                <p className="text-sm text-gray-600">Sample Type</p>
                <p className="text-gray-900 capitalize">{sampleType}</p>
              </div>
              <div className="p-3 bg-gray-50 rounded-md border border-gray-200">
                <p className="text-sm text-gray-600">Run Scope</p>
                <p className="text-gray-900">{runScope === 'qc' ? 'QC Only' : 'Full Pipeline'}</p>
              </div>
            </div>

            <button
              onClick={handleRun}
              disabled={running}
              className="w-full bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white px-4 py-3 rounded-md flex items-center justify-center gap-2 transition-colors"
            >
              {running ? (
                <>
                  <div className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin" />
                  Running Pipeline...
                </>
              ) : (
                <>
                  <Play className="w-5 h-5" />
                  Run Pipeline
                </>
              )}
            </button>

            {sampleType === 'vaginal' && valenciaClass === 'yes' && (
              <div className="mt-4 p-3 bg-blue-50 border border-blue-200 rounded-md">
                <p className="text-sm text-blue-900">VALENCIA classification will be performed</p>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}