import { Dna } from 'lucide-react';

export function Header() {
  return (
    <header className="bg-white border-b border-gray-200 shadow-sm">
      <div className="max-w-7xl mx-auto px-6 py-4">
        <div className="flex items-center gap-3">
          <Dna className="w-8 h-8 text-blue-600" />
          <div>
            <h1 className="text-gray-900">STAMINA-BIOME</h1>
            <p className="text-gray-600 text-sm">Long Read & Short Read Bioinformatics Analysis</p>
          </div>
        </div>
      </div>
    </header>
  );
}