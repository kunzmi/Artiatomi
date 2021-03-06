//  Copyright (c) 2018, Michael Kunz and Frangakis Lab, BMLS,
//  Goethe University, Frankfurt am Main.
//  All rights reserved.
//  http://kunzmi.github.io/Artiatomi
//  
//  This file is part of the Artiatomi package.
//  
//  Artiatomi is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//  
//  Artiatomi is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//  
//  You should have received a copy of the GNU General Public License
//  along with Artiatomi. If not, see <http://www.gnu.org/licenses/>.
//  
////////////////////////////////////////////////////////////////////////


#include "CtfFile.h"

CtfFile::CtfFile(std::string aFileName)
	: EMFile(aFileName)
{
	OpenAndRead();
	ReadHeaderInfo();
}

float CtfFile::GetMinDefocus(uint index)
{
	float* fdata = (float*)_data;
	return fdata[1 * DimX + index];
}

float CtfFile::GetMaxDefocus(uint index)
{
	float* fdata = (float*)_data;
	return fdata[2 * DimX + index];
}

float CtfFile::GetAstigmatismAngle(uint index)
{
	float* fdata = (float*)_data;
	return fdata[4 * DimX + index] * 180.0f / M_PI;
}